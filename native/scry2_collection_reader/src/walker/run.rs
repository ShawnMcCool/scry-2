//! Top-level walker orchestrator.
//!
//! Stitches every walker primitive into one entry point that the NIF
//! shell can call:
//!
//! ```text
//! list_maps  → locate `mono-2.0-bdwgc.dll` + stitch its sections
//!            → domain::find_root_domain
//!            → image_lookup × {Core, Assembly-CSharp, mscorlib}
//!            → class_lookup × {PAPA, InventoryManager,
//!                              InventoryServiceWrapper,
//!                              ClientPlayerInventory, Dictionary`2}
//!            → read MonoClassDef blobs for each class
//!            → chain::from_papa_class
//!            → WalkResult { entries, inventory }
//! ```
//!
//! The function takes a pre-fetched `maps` slice and a
//! `read_mem(addr, len) -> Option<Vec<u8>>` closure rather than calling
//! into `crate::platform` directly. This keeps the orchestrator pure
//! (no /proc, no syscalls) so unit tests can drive it with a
//! `FakeMem`-style fixture.

use super::card_holder;
use super::chain;
use super::class_lookup;
use super::dict::DictEntry;
use super::domain;
use super::field;
use super::image_lookup;
use super::inventory::InventoryValues;
use super::match_info::{self, MatchInfoValues};
use super::match_scene;
use super::mono::{self, MonoOffsets};
use super::vtable;
use crate::discovery_cache::{self, AnchorKind};

// `CLASS_DEF_BLOB_LEN` lives on `super::mono`; the spike binaries import
// it from here for ergonomics.
pub use super::mono::CLASS_DEF_BLOB_LEN;

/// Filename substring that identifies MTGA's Mono runtime DLL on
/// every platform. `/proc/<pid>/maps` paths can be Wine-style with
/// drive letters and arbitrary case; matching is case-insensitive
/// against the basename portion.
pub const MONO_DLL_NEEDLE: &str = "mono-2.0-bdwgc.dll";

/// Failure modes for [`walk_collection`]. Variants intentionally
/// carry the **specific** thing that wasn't found so the Elixir
/// `Scry2.Collection.Reader` (per ADR-034) can route loudly.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WalkError {
    /// `mono-2.0-bdwgc.dll` is not loaded in the target process.
    MonoDllNotFound,
    /// Found the DLL in `/proc/<pid>/maps` but at least one of its
    /// mapped regions can't be read. Often means the process exited
    /// between the maps snapshot and the reads.
    MonoDllReadFailed,
    /// `mono_get_root_domain` couldn't be decoded. Either the symbol
    /// isn't exported, the prologue doesn't match the expected
    /// `mov rax,[rip+disp32]; ret` shape, or the static slot is null.
    RootDomainNotFound,
    /// A required managed assembly couldn't be found in the root
    /// domain's `domain_assemblies` list.
    AssemblyNotFound(&'static str),
    /// A required managed class couldn't be found in any of its
    /// candidate images' `class_cache` tables.
    ClassNotFound(&'static str),
    /// Found the class but couldn't read its `MonoClassDef` bytes.
    ClassReadFailed(&'static str),
    /// Reached the chain orchestrator but at least one of the inner
    /// pointer hops failed (null field, unresolved name, etc.).
    /// Reported as a single variant since the inner walker doesn't
    /// distinguish — see [`chain::from_papa_class`].
    ChainFailed,
}

/// Full walk result returned by [`walk_collection`]. Wraps
/// [`chain::WalkResult`] and adds the disk-sourced
/// `mtga_build_hint`. Only `PartialEq` is derivable because
/// `InventoryValues` carries an `f64` (`vault_progress`).
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    /// Used entries from the `Cards` dictionary.
    pub entries: Vec<DictEntry>,
    /// Wildcards / currencies / vault progress.
    pub inventory: InventoryValues,
    /// Booster inventory — `(collation_id, count)` rows.
    pub boosters: Vec<super::boosters::BoosterRow>,
    /// MTGA build GUID from `boot.config`, or `None` if the file
    /// couldn't be located or parsed. Useful as a sanity check on
    /// top of walker output: when the GUID changes between runs the
    /// walker offsets may have shifted.
    pub mtga_build_hint: Option<String>,
}

/// One row in `/proc/<pid>/maps`-style output, in the shape
/// `crate::platform::list_maps` already returns.
pub type MapEntry = (u64, u64, String, Option<String>);

/// Run the full walker against a target process.
///
/// `maps` is the output of `list_maps(pid)`. `read_mem(addr, len)`
/// reads `len` bytes from the target process at remote address
/// `addr`, returning `None` on any failure. `build_hint` is invoked
/// once after the chain succeeds — split out as a closure so unit
/// tests stay disk-free; the NIF wrapper passes a closure that
/// composes [`super::build_hint::find_mtga_root`] +
/// [`super::build_hint::read_build_guid`].
pub fn walk_collection<F, B>(
    maps: &[MapEntry],
    read_mem: F,
    build_hint: B,
) -> Result<Snapshot, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
    B: FnOnce() -> Option<String>,
{
    let offsets = MonoOffsets::mtga_default();

    let (mono_base, mono_bytes) =
        read_mono_image(maps, &read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    if mono_bytes.is_empty() {
        return Err(WalkError::MonoDllNotFound);
    }

    let domain_addr = domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;

    // PAPA is the only class we need to look up by name — every
    // class downstream is derived at runtime from its instance's
    // vtable (handles MTGA's build-variant inventory wrapper +
    // closed-generic dictionary classes).
    let all_images = image_lookup::list_all_images(&offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    if all_images.is_empty() {
        return Err(WalkError::RootDomainNotFound);
    }

    let papa_addr = find_class_in_images(&offsets, &all_images, "PAPA", read_mem)
        .ok_or(WalkError::ClassNotFound("PAPA"))?;
    let papa_bytes =
        read_mem(papa_addr, CLASS_DEF_BLOB_LEN).ok_or(WalkError::ClassReadFailed("PAPA"))?;

    // The runtime class of the cards dictionary is the closed-generic
    // `Dictionary<int,int>` (a `MonoClassGenericInst`), not a
    // `MonoClassDef`. Field metadata for `_entries` lives on the
    // open-generic `Dictionary\`2` definition — we look that up by
    // name and pass it explicitly through the chain.
    let dict_addr = find_class_in_images(&offsets, &all_images, "Dictionary`2", read_mem)
        .ok_or(WalkError::ClassNotFound("Dictionary`2"))?;
    let dict_bytes = read_mem(dict_addr, CLASS_DEF_BLOB_LEN)
        .ok_or(WalkError::ClassReadFailed("Dictionary`2"))?;

    let walk = chain::from_papa_class(
        &offsets,
        papa_addr,
        domain_addr,
        &papa_bytes,
        &dict_bytes,
        read_mem,
    )
    .ok_or(WalkError::ChainFailed)?;

    Ok(Snapshot {
        entries: walk.entries,
        inventory: walk.inventory,
        boosters: walk.boosters,
        mtga_build_hint: build_hint(),
    })
}

/// Run the match-info walker (Chain 1) against a target process.
///
/// Resolves PAPA, reads its singleton via vtable static storage, then
/// delegates to [`super::match_info::from_papa_singleton`].
///
/// Returns `Ok(None)` when the chain reaches PAPA but `MatchManager`
/// is null (no active match) — this is a normal state, not an error.
/// Returns `Err(WalkError)` for upstream failures (mono DLL missing,
/// PAPA class missing, etc.).
pub fn walk_match_info<F>(
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<MatchInfoValues>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let (mono_base, mono_bytes) =
        read_mono_image(maps, &read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    if mono_bytes.is_empty() {
        return Err(WalkError::MonoDllNotFound);
    }

    let domain_addr = domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;

    let images = image_lookup::list_all_images(&offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    if images.is_empty() {
        return Err(WalkError::RootDomainNotFound);
    }

    let papa_addr = find_class_in_images(&offsets, &images, "PAPA", read_mem)
        .ok_or(WalkError::ClassNotFound("PAPA"))?;
    let papa_bytes =
        read_mem(papa_addr, CLASS_DEF_BLOB_LEN).ok_or(WalkError::ClassReadFailed("PAPA"))?;

    // PAPA._instance — static field via vtable storage.
    let instance_field = field::find_field_by_name(&offsets, &papa_bytes, "_instance", read_mem)
        .ok_or(WalkError::ChainFailed)?;
    if !instance_field.is_static || instance_field.offset < 0 {
        return Err(WalkError::ChainFailed);
    }
    let storage = vtable::static_storage_base(&offsets, papa_addr, domain_addr, read_mem)
        .ok_or(WalkError::ChainFailed)?;
    let static_addr = storage + instance_field.offset as u64;
    let papa_singleton = read_mem(static_addr, 8)
        .and_then(|b| mono::read_u64(&b, 0, 0))
        .ok_or(WalkError::ChainFailed)?;
    if papa_singleton == 0 {
        // PAPA exists but its singleton hasn't been initialised — not
        // an active match, return None.
        return Ok(None);
    }

    Ok(match_info::from_papa_singleton(
        &offsets,
        papa_singleton,
        &papa_bytes,
        read_mem,
    ))
}

/// One (seat, zone, arena_ids) triple in [`BoardSnapshot`]. `seat_id`
/// and `zone_id` are MTGA's own enum integers — keep them opaque at
/// the walker boundary; symbolic translation is the caller's job.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ZoneCards {
    pub seat_id: i32,
    pub zone_id: i32,
    pub arena_ids: Vec<i32>,
}

/// Snapshot of every readable card across every zone in the active
/// match. Returned by [`walk_match_board`].
///
/// Populates entries for Hand (3), Battlefield (4), Graveyard (5),
/// and Exile (6). Stack and Command are intentionally not walked.
/// Empty zones are omitted from the result entirely (no zero-length
/// `ZoneCards` rows reach the wire).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct BoardSnapshot {
    pub zones: Vec<ZoneCards>,
}

/// Run the board-state walker (Chain 2) against a target process.
///
/// Resolves `MatchSceneManager.Instance` (the static singleton),
/// walks to its `PlayerTypeMap`, then for every (seat, zone) entry
/// drills the holder for arena_ids across Hand (3), Battlefield (4),
/// Graveyard (5), and Exile (6).
///
/// Returns `Ok(None)` when MTGA is reachable but
/// `MatchSceneManager.Instance` is null — i.e. no active match scene
/// (the duel UI hasn't loaded, or it's torn down). Treat as the
/// authoritative "wind down polling" signal.
pub fn walk_match_board<F>(
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<BoardSnapshot>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let (mono_base, mono_bytes) =
        read_mono_image(maps, &read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    if mono_bytes.is_empty() {
        return Err(WalkError::MonoDllNotFound);
    }

    let domain_addr = domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;

    let images = image_lookup::list_all_images(&offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    if images.is_empty() {
        return Err(WalkError::RootDomainNotFound);
    }

    let scene_class_addr = find_class_in_images(&offsets, &images, "MatchSceneManager", read_mem)
        .ok_or(WalkError::ClassNotFound("MatchSceneManager"))?;
    let scene_class_bytes = read_mem(scene_class_addr, CLASS_DEF_BLOB_LEN)
        .ok_or(WalkError::ClassReadFailed("MatchSceneManager"))?;

    let scene_singleton = match match_scene::find_scene_singleton(
        &offsets,
        scene_class_addr,
        &scene_class_bytes,
        domain_addr,
        read_mem,
    ) {
        Some(addr) => addr,
        None => return Ok(None), // No active match scene — normal state.
    };

    let (ptm_addr, ptm_class_bytes) =
        match match_scene::walk_to_player_type_map(&offsets, scene_singleton, read_mem) {
            Some(p) => p,
            None => return Ok(None),
        };

    let seat_zone_map =
        match match_scene::read_seat_zone_map(&offsets, ptm_addr, &ptm_class_bytes, read_mem) {
            Some(m) => m,
            None => return Ok(None),
        };

    let mut zones = Vec::new();
    for seat in &seat_zone_map.seats {
        for zone in &seat.zones {
            if !card_holder::READABLE_ZONES.contains(&zone.zone_id) {
                continue;
            }
            if zone.holder_addr == 0 {
                continue;
            }
            if let Some(arena_ids) =
                card_holder::read_zone_arena_ids(&offsets, zone.holder_addr, zone.zone_id, read_mem)
            {
                if arena_ids.is_empty() {
                    continue;
                }
                zones.push(ZoneCards {
                    seat_id: seat.seat_id,
                    zone_id: zone.zone_id,
                    arena_ids,
                });
            }
        }
    }

    Ok(Some(BoardSnapshot { zones }))
}

// ============================================================
// Cached variants — same chain logic, but expensive discovery
// (mono image stitch + root_domain + image enumeration + class
// lookup by name) goes through `discovery_cache` keyed by pid.
// First call after MTGA starts pays full cost; every subsequent
// call drops two orders of magnitude (~few hundred reads instead
// of ~65k).
//
// On any chain failure that may indicate stale cache, the caller
// (NIF wrapper) is expected to call `discovery_cache::invalidate(pid)`
// and retry once. The cache module's docstring covers the contract.
// ============================================================

/// Cached variant of [`walk_match_info`]. See module-level cache
/// rationale and the note on stale-entry handling.
pub fn walk_match_info_cached<F>(
    pid: u32,
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<MatchInfoValues>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let mono_image =
        discovery_cache::get_mono_image(pid, maps, read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    let domain_addr = discovery_cache::get_root_domain(pid, &mono_image, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let images = discovery_cache::get_all_images(pid, &offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let papa = discovery_cache::get_anchor(
        pid,
        AnchorKind::Papa,
        &offsets,
        &images,
        "PAPA",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("PAPA"))?;

    // PAPA._instance — static field via vtable storage. Exactly the
    // same code path as `walk_match_info` from this point on.
    let instance_field =
        field::find_field_by_name(&offsets, &papa.class_bytes, "_instance", read_mem)
            .ok_or(WalkError::ChainFailed)?;
    if !instance_field.is_static || instance_field.offset < 0 {
        return Err(WalkError::ChainFailed);
    }
    let storage = vtable::static_storage_base(&offsets, papa.class_addr, domain_addr, read_mem)
        .ok_or(WalkError::ChainFailed)?;
    let static_addr = storage + instance_field.offset as u64;
    let papa_singleton = read_mem(static_addr, 8)
        .and_then(|b| mono::read_u64(&b, 0, 0))
        .ok_or(WalkError::ChainFailed)?;
    if papa_singleton == 0 {
        return Ok(None);
    }

    Ok(match_info::from_papa_singleton(
        &offsets,
        papa_singleton,
        &papa.class_bytes,
        read_mem,
    ))
}

/// Cached variant of `walk_mastery`. Reuses the per-pid PAPA anchor
/// from the discovery cache — second walk per snapshot pays no
/// discovery cost.
///
/// Resolves PAPA, reads its singleton via vtable static storage, then
/// delegates to [`super::mastery::from_papa_singleton`].
///
/// Returns `Ok(None)` when the chain reaches PAPA but its singleton is
/// null, or when the mastery sub-chain is unreachable (between
/// seasons / harness build / strategy class mismatch). Returns
/// `Err(WalkError)` for upstream failures (mono DLL missing, PAPA
/// class missing, etc.).
pub fn walk_mastery_cached<F>(
    pid: u32,
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<crate::walker::mastery::MasteryInfo>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let mono_image =
        discovery_cache::get_mono_image(pid, maps, read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    let domain_addr = discovery_cache::get_root_domain(pid, &mono_image, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let images = discovery_cache::get_all_images(pid, &offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let papa = discovery_cache::get_anchor(
        pid,
        AnchorKind::Papa,
        &offsets,
        &images,
        "PAPA",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("PAPA"))?;

    // PAPA._instance — static field via vtable storage. Same code
    // path as `walk_match_info_cached` from this point on.
    let instance_field =
        field::find_field_by_name(&offsets, &papa.class_bytes, "_instance", read_mem)
            .ok_or(WalkError::ChainFailed)?;
    if !instance_field.is_static || instance_field.offset < 0 {
        return Err(WalkError::ChainFailed);
    }
    let storage = vtable::static_storage_base(&offsets, papa.class_addr, domain_addr, read_mem)
        .ok_or(WalkError::ChainFailed)?;
    let static_addr = storage + instance_field.offset as u64;
    let papa_singleton = read_mem(static_addr, 8)
        .and_then(|b| mono::read_u64(&b, 0, 0))
        .ok_or(WalkError::ChainFailed)?;
    if papa_singleton == 0 {
        return Ok(None);
    }

    Ok(crate::walker::mastery::from_papa_singleton(
        &offsets,
        papa_singleton,
        &papa.class_bytes,
        read_mem,
    ))
}

/// Cached walker entry point for the active-events list (Chain 3).
///
/// Same discovery-cache pattern as
/// [`walk_mastery_cached`]/[`walk_match_info_cached`]: get
/// mono image / root domain / images / PAPA from cache, then read
/// `PAPA._instance` and hand off to
/// [`crate::walker::event_manager::from_papa_singleton`].
///
/// `Ok(None)` when `PAPA._instance` is null (pre-login MTGA) or when
/// the EventManager anchor itself is null. `Ok(Some(EventList { records: [] }))`
/// when the chain resolves but the list is empty. `Err(_)` only on
/// hard discovery failures (mono dll unreadable, root domain missing,
/// PAPA class not found).
pub fn walk_events_cached<F>(
    pid: u32,
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<crate::walker::event_manager::EventList>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let mono_image =
        discovery_cache::get_mono_image(pid, maps, read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    let domain_addr = discovery_cache::get_root_domain(pid, &mono_image, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let images = discovery_cache::get_all_images(pid, &offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let papa = discovery_cache::get_anchor(
        pid,
        AnchorKind::Papa,
        &offsets,
        &images,
        "PAPA",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("PAPA"))?;

    let instance_field =
        field::find_field_by_name(&offsets, &papa.class_bytes, "_instance", read_mem)
            .ok_or(WalkError::ChainFailed)?;
    if !instance_field.is_static || instance_field.offset < 0 {
        return Err(WalkError::ChainFailed);
    }
    let storage = vtable::static_storage_base(&offsets, papa.class_addr, domain_addr, read_mem)
        .ok_or(WalkError::ChainFailed)?;
    let static_addr = storage + instance_field.offset as u64;
    let papa_singleton = read_mem(static_addr, 8)
        .and_then(|b| mono::read_u64(&b, 0, 0))
        .ok_or(WalkError::ChainFailed)?;
    if papa_singleton == 0 {
        return Ok(None);
    }

    Ok(crate::walker::event_manager::from_papa_singleton(
        &offsets,
        papa_singleton,
        &papa.class_bytes,
        read_mem,
    ))
}

/// Cached walker entry point for account identity (spike 22).
///
/// Same discovery-cache pattern as the other `walk_*_cached`
/// wrappers: get mono image / root domain / images / PAPA from cache,
/// then read `PAPA._instance` and hand off to
/// [`crate::walker::account::from_papa_singleton`].
///
/// `Ok(None)` when `PAPA._instance` is null (pre-login MTGA) or when
/// the chain hops short (AccountClient or AccountInformation null).
/// `Ok(Some(AccountIdentity { ... }))` otherwise. `Err(_)` only on
/// hard discovery failures.
pub fn walk_account_cached<F>(
    pid: u32,
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<crate::walker::account::AccountIdentity>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let mono_image =
        discovery_cache::get_mono_image(pid, maps, read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    let domain_addr = discovery_cache::get_root_domain(pid, &mono_image, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let images = discovery_cache::get_all_images(pid, &offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let papa = discovery_cache::get_anchor(
        pid,
        AnchorKind::Papa,
        &offsets,
        &images,
        "PAPA",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("PAPA"))?;

    let instance_field =
        field::find_field_by_name(&offsets, &papa.class_bytes, "_instance", read_mem)
            .ok_or(WalkError::ChainFailed)?;
    if !instance_field.is_static || instance_field.offset < 0 {
        return Err(WalkError::ChainFailed);
    }
    let storage = vtable::static_storage_base(&offsets, papa.class_addr, domain_addr, read_mem)
        .ok_or(WalkError::ChainFailed)?;
    let static_addr = storage + instance_field.offset as u64;
    let papa_singleton = read_mem(static_addr, 8)
        .and_then(|b| mono::read_u64(&b, 0, 0))
        .ok_or(WalkError::ChainFailed)?;
    if papa_singleton == 0 {
        return Ok(None);
    }

    Ok(crate::walker::account::from_papa_singleton(
        &offsets,
        papa_singleton,
        &papa.class_bytes,
        read_mem,
    ))
}

/// Cached variant of [`walk_match_board`]. See module-level cache
/// rationale and the note on stale-entry handling.
pub fn walk_match_board_cached<F>(
    pid: u32,
    maps: &[MapEntry],
    read_mem: F,
) -> Result<Option<BoardSnapshot>, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let offsets = MonoOffsets::mtga_default();

    let mono_image =
        discovery_cache::get_mono_image(pid, maps, read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    let domain_addr = discovery_cache::get_root_domain(pid, &mono_image, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let images = discovery_cache::get_all_images(pid, &offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let scene = discovery_cache::get_anchor(
        pid,
        AnchorKind::Scene,
        &offsets,
        &images,
        "MatchSceneManager",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("MatchSceneManager"))?;

    let scene_singleton = match match_scene::find_scene_singleton(
        &offsets,
        scene.class_addr,
        &scene.class_bytes,
        domain_addr,
        read_mem,
    ) {
        Some(addr) => addr,
        None => return Ok(None),
    };

    let (ptm_addr, ptm_class_bytes) =
        match match_scene::walk_to_player_type_map(&offsets, scene_singleton, read_mem) {
            Some(p) => p,
            None => return Ok(None),
        };

    let seat_zone_map =
        match match_scene::read_seat_zone_map(&offsets, ptm_addr, &ptm_class_bytes, read_mem) {
            Some(m) => m,
            None => return Ok(None),
        };

    let mut zones = Vec::new();
    for seat in &seat_zone_map.seats {
        for zone in &seat.zones {
            if !card_holder::READABLE_ZONES.contains(&zone.zone_id) {
                continue;
            }
            if zone.holder_addr == 0 {
                continue;
            }
            if let Some(arena_ids) =
                card_holder::read_zone_arena_ids(&offsets, zone.holder_addr, zone.zone_id, read_mem)
            {
                if arena_ids.is_empty() {
                    continue;
                }
                zones.push(ZoneCards {
                    seat_id: seat.seat_id,
                    zone_id: zone.zone_id,
                    arena_ids,
                });
            }
        }
    }

    Ok(Some(BoardSnapshot { zones }))
}

/// Cached variant of [`walk_collection`]. See module-level cache
/// rationale and the note on stale-entry handling.
pub fn walk_collection_cached<F, B>(
    pid: u32,
    maps: &[MapEntry],
    read_mem: F,
    build_hint: B,
) -> Result<Snapshot, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
    B: FnOnce() -> Option<String>,
{
    let offsets = MonoOffsets::mtga_default();

    let mono_image =
        discovery_cache::get_mono_image(pid, maps, read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    let domain_addr = discovery_cache::get_root_domain(pid, &mono_image, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let images = discovery_cache::get_all_images(pid, &offsets, domain_addr, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;
    let papa = discovery_cache::get_anchor(
        pid,
        AnchorKind::Papa,
        &offsets,
        &images,
        "PAPA",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("PAPA"))?;
    let dict = discovery_cache::get_anchor(
        pid,
        AnchorKind::DictGeneric,
        &offsets,
        &images,
        "Dictionary`2",
        CLASS_DEF_BLOB_LEN,
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("Dictionary`2"))?;

    let walk = chain::from_papa_class(
        &offsets,
        papa.class_addr,
        domain_addr,
        &papa.class_bytes,
        &dict.class_bytes,
        read_mem,
    )
    .ok_or(WalkError::ChainFailed)?;

    Ok(Snapshot {
        entries: walk.entries,
        inventory: walk.inventory,
        boosters: walk.boosters,
        mtga_build_hint: build_hint(),
    })
}

/// Locate the mono DLL in `maps`, stitch all its mapped sections
/// into one contiguous buffer indexed by RVA, and return
/// `(base, bytes)`.
///
/// Returns `None` if the DLL isn't loaded *or* every mapped region
/// of it fails to read. A partial read (some sections succeed,
/// others fail) yields `Some((base, bytes))` with the failed regions
/// zero-filled; PE parsing will still find headers and exports as
/// long as the sections it references come back.
///
/// Implementation note: under Wine the loader maps **only the PE
/// header** (and a handful of file-backed sections like `.pdata`)
/// with the DLL path attached; the heavyweight `.text` / `.rdata` /
/// `.data` sections live in **anonymous** regions immediately
/// adjacent to the header. The walker therefore anchors on any
/// region whose path matches the DLL and then walks left/right
/// across physically-adjacent regions whose path is either the
/// same DLL or empty/anonymous, producing one buffer that covers
/// the whole loaded image.
pub fn read_mono_image<F>(maps: &[MapEntry], read_mem: &F) -> Option<(u64, Vec<u8>)>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let anchor_idx = maps
        .iter()
        .position(|(_, _, _, path)| path_matches_mono_dll(path.as_deref()))?;
    let dll_path = maps[anchor_idx].3.clone();

    let mut start_idx = anchor_idx;
    while start_idx > 0 {
        let prev = &maps[start_idx - 1];
        let curr = &maps[start_idx];
        if prev.1 == curr.0 && is_image_extension(&prev.3, dll_path.as_deref()) {
            start_idx -= 1;
        } else {
            break;
        }
    }

    let mut end_idx = anchor_idx;
    while end_idx + 1 < maps.len() {
        let curr = &maps[end_idx];
        let next = &maps[end_idx + 1];
        if curr.1 == next.0 && is_image_extension(&next.3, dll_path.as_deref()) {
            end_idx += 1;
        } else {
            break;
        }
    }

    let base = maps[start_idx].0;
    let max_end = maps[end_idx].1;
    let span = (max_end - base) as usize;
    let mut buf = vec![0u8; span];

    let mut any_read = false;
    for region in &maps[start_idx..=end_idx] {
        let off = (region.0 - base) as usize;
        let len = (region.1 - region.0) as usize;
        if let Some(bytes) = read_mem(region.0, len) {
            let copy_len = bytes.len().min(len);
            buf[off..off + copy_len].copy_from_slice(&bytes[..copy_len]);
            any_read = true;
        }
    }
    if !any_read {
        return None;
    }
    Some((base, buf))
}

/// Case-insensitive match on the path's basename (or, when the
/// loader gives us a Wine-style `\` path, the trailing component
/// after `\` or `/`).
fn path_matches_mono_dll(path: Option<&str>) -> bool {
    let path = match path {
        Some(p) => p,
        None => return false,
    };
    let basename = path.rsplit(['/', '\\']).next().unwrap_or(path);
    basename.eq_ignore_ascii_case(MONO_DLL_NEEDLE)
}

/// True for adjacent regions that should be stitched into the same
/// image as the anchor: the same DLL path (later sections of the
/// image, e.g. `.pdata`), an unrelated mono DLL hit (shouldn't
/// happen but handled), or an anonymous / empty-path region (the
/// Wine loader's heap-allocated `.text`/`.rdata`/`.data` slabs).
fn is_image_extension(path: &Option<String>, dll_path: Option<&str>) -> bool {
    match path.as_deref() {
        None => true,
        Some("") => true,
        Some(p) => path_matches_mono_dll(Some(p)) || dll_path == Some(p),
    }
}

/// Try `class_lookup::find_class_by_name` against each image in turn,
/// returning the first hit.
fn find_class_in_images<F>(
    offsets: &MonoOffsets,
    images: &[u64],
    target: &str,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    for image in images {
        if let Some(addr) = class_lookup::find_class_by_name(offsets, *image, target, read_mem) {
            return Some(addr);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::test_support::FakeMem;

    #[test]
    fn path_match_accepts_unix_paths() {
        assert!(path_matches_mono_dll(Some(
            "/home/x/.steam/.../EmbedRuntime/mono-2.0-bdwgc.dll"
        )));
    }

    #[test]
    fn path_match_accepts_wine_style_paths() {
        assert!(path_matches_mono_dll(Some(
            r"Z:\Steam\steamapps\common\MTGA\MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll"
        )));
    }

    #[test]
    fn path_match_is_case_insensitive() {
        assert!(path_matches_mono_dll(Some("/path/to/Mono-2.0-BDWGC.DLL")));
    }

    #[test]
    fn path_match_rejects_unrelated_dlls() {
        assert!(!path_matches_mono_dll(Some("/path/to/some-other.dll")));
        assert!(!path_matches_mono_dll(Some("/path/to/mono.dll")));
        assert!(!path_matches_mono_dll(None));
    }

    #[test]
    fn read_mono_image_stitches_wine_style_layout() -> Result<(), String> {
        // Real Wine/Linux layout: the loader maps the PE header and a
        // handful of file-backed sections under the DLL path; the
        // .text/.rdata/.data slabs end up as adjacent **anonymous**
        // regions. /proc/<pid>/maps is always physically contiguous
        // through the whole image — no gaps inside.
        let base: u64 = 0x180000000;
        let maps: Vec<MapEntry> = vec![
            // unrelated region just below the image
            (
                base - 0x2000,
                base,
                "r--p".to_string(),
                Some("/lib/below.so".to_string()),
            ),
            // PE header (file off 0)
            (
                base,
                base + 0x1000,
                "r--p".to_string(),
                Some("/abs/mono-2.0-bdwgc.dll".to_string()),
            ),
            // .text — anonymous, adjacent
            (base + 0x1000, base + 0x2000, "r-xp".to_string(), None),
            // .rdata — anonymous (empty path, also anonymous), adjacent
            (
                base + 0x2000,
                base + 0x2800,
                "r--p".to_string(),
                Some("".to_string()),
            ),
            // .pdata — DLL path, adjacent
            (
                base + 0x2800,
                base + 0x3000,
                "r--p".to_string(),
                Some("/abs/mono-2.0-bdwgc.dll".to_string()),
            ),
            // .reloc — anonymous, adjacent
            (base + 0x3000, base + 0x3100, "r--p".to_string(), None),
            // unrelated DLL right after the image (no gap) — must NOT be included
            (
                base + 0x3100,
                base + 0x4000,
                "r--p".to_string(),
                Some("/lib/other.so".to_string()),
            ),
        ];
        let mut mem = FakeMem::default();
        mem.add(base, {
            let mut v = vec![0u8; 0x1000];
            v[0] = 0x11;
            v
        });
        mem.add(base + 0x1000, {
            let mut v = vec![0u8; 0x1000];
            v[0] = 0x22;
            v
        });
        mem.add(base + 0x2000, {
            let mut v = vec![0u8; 0x800];
            v[0] = 0x33;
            v
        });
        mem.add(base + 0x2800, {
            let mut v = vec![0u8; 0x800];
            v[0] = 0x44;
            v
        });
        mem.add(base + 0x3000, {
            let mut v = vec![0u8; 0x100];
            v[0] = 0x55;
            v
        });

        let (got_base, bytes) =
            read_mono_image(&maps, &|a, l| mem.read(a, l)).ok_or("stitch should succeed")?;
        assert_eq!(got_base, base);
        assert_eq!(bytes.len(), 0x3100);
        assert_eq!(bytes[0], 0x11);
        assert_eq!(bytes[0x1000], 0x22);
        assert_eq!(bytes[0x2000], 0x33);
        assert_eq!(bytes[0x2800], 0x44);
        assert_eq!(bytes[0x3000], 0x55);
        Ok(())
    }

    #[test]
    fn read_mono_image_stops_at_unrelated_dll_path() -> Result<(), String> {
        // If an unrelated DLL is mapped immediately adjacent to the
        // mono image, the walker must NOT include it in the stitch.
        let base: u64 = 0x180000000;
        let maps: Vec<MapEntry> = vec![
            (
                base,
                base + 0x1000,
                "r--p".to_string(),
                Some("/abs/mono-2.0-bdwgc.dll".to_string()),
            ),
            (
                base + 0x1000,
                base + 0x2000,
                "r--p".to_string(),
                Some("/lib/winevulkan.dll".to_string()),
            ),
        ];
        let mut mem = FakeMem::default();
        mem.add(base, vec![0xaau8; 0x1000]);
        mem.add(base + 0x1000, vec![0xbbu8; 0x1000]);

        let (got_base, bytes) =
            read_mono_image(&maps, &|a, l| mem.read(a, l)).ok_or("stitch should succeed")?;
        assert_eq!(got_base, base);
        // Only the mono region got included (0x1000 bytes), winevulkan was excluded.
        assert_eq!(bytes.len(), 0x1000);
        assert_eq!(bytes[0], 0xaa);
        Ok(())
    }

    #[test]
    fn read_mono_image_returns_none_when_dll_missing() {
        let maps: Vec<MapEntry> = vec![(
            0x1000,
            0x2000,
            "r--p".to_string(),
            Some("/lib/unrelated.so".to_string()),
        )];
        let mem = FakeMem::default();
        assert!(read_mono_image(&maps, &|a, l| mem.read(a, l)).is_none());
    }

    #[test]
    fn read_mono_image_returns_none_when_every_region_unreadable() {
        // DLL is in the maps but read_mem misses every region.
        let base: u64 = 0x180000000;
        let maps: Vec<MapEntry> = vec![(
            base,
            base + 0x1000,
            "r-xp".to_string(),
            Some("/abs/mono-2.0-bdwgc.dll".to_string()),
        )];
        let mem = FakeMem::default();
        assert!(read_mono_image(&maps, &|a, l| mem.read(a, l)).is_none());
    }

    #[test]
    fn walk_collection_returns_dll_not_found_when_mono_missing() {
        let maps: Vec<MapEntry> = vec![];
        let mem = FakeMem::default();
        assert_eq!(
            walk_collection(&maps, |a, l| mem.read(a, l), || None),
            Err(WalkError::MonoDllReadFailed)
        );
    }

    #[test]
    fn walk_collection_unwinds_when_read_budget_is_exhausted() {
        // Integration test for `read_budget::bounded`: when the
        // walker is given a closure whose reads are starved by an
        // exhausted budget, every chain step sees `None` and the
        // walker unwinds with an explicit error rather than spinning.
        //
        // We construct a maps list that contains a mono DLL entry —
        // so `read_mono_image` finds an anchor — but every read
        // fails because the budget hits zero on the very first call.
        // The walker must terminate with `MonoDllReadFailed`; not
        // panic, not loop.
        use std::sync::atomic::AtomicU64;
        let base: u64 = 0x180000000;
        let maps: Vec<MapEntry> = vec![(
            base,
            base + 0x1000,
            "r--p".to_string(),
            Some("/abs/mono-2.0-bdwgc.dll".to_string()),
        )];
        let mem = FakeMem::default();
        let counter = AtomicU64::new(0);
        let inner = |a: u64, l: usize| mem.read(a, l);
        // Budget = 0 starves every read.
        let bounded = crate::read_budget::bounded(&counter, 0, inner);

        let result = walk_collection(&maps, bounded, || None);
        assert_eq!(
            result,
            Err(WalkError::MonoDllReadFailed),
            "exhausted budget must surface as a walk error, not a hang"
        );
    }
}
