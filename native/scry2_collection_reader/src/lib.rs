//! scry2_collection_reader — memory-reader NIF crate (ADR 034).
//!
//! Exposes four NIFs used by `Scry2.Collection.Reader`:
//!   * `read_bytes(pid, addr, size)`       — read remote process memory
//!   * `list_maps(pid)`                    — enumerate mapped regions
//!   * `list_processes()`                  — enumerate running processes
//!   * `walk_collection(pid)`              — run the whole walker pipeline
//!
//! Plus `ping/0` as an NIF-load heartbeat.
//!
//! Platform impls live in `linux.rs` / `windows.rs` / `macos.rs`;
//! only Linux is implemented today, the others return `:not_implemented`.
//!
//! Every NIF runs on the `DirtyIo` scheduler — all primitives hit the
//! filesystem or syscalls and would otherwise starve the regular
//! schedulers.

#![deny(clippy::panic, clippy::unwrap_used, clippy::expect_used)]

use rustler::{Atom, Binary, Env, NifMap, NifTaggedEnum, NifTuple, OwnedBinary};

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub use linux as platform;

pub mod read_budget;
pub mod walker;

use read_budget::{bounded, WALK_READ_BUDGET};
use std::sync::atomic::AtomicU64;

#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub use macos as platform;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as platform;

mod atoms {
    rustler::atoms! {
        pong,
        unmapped,
        no_process,
        permission_denied,
        io_error,
        not_implemented,
    }
}

/// One row from `/proc/<pid>/maps` (or the platform equivalent):
/// `(start_addr, end_addr, perms, path?)`.
pub type MapEntry = (u64, u64, String, Option<String>);

/// Platform-level failure modes; mapped into atoms at the NIF boundary.
#[derive(Debug)]
pub enum PlatformError {
    Unmapped,
    NoProcess,
    PermissionDenied,
    IoError,
    NotImplemented,
}

fn err_atom(e: PlatformError) -> Atom {
    match e {
        PlatformError::Unmapped => atoms::unmapped(),
        PlatformError::NoProcess => atoms::no_process(),
        PlatformError::PermissionDenied => atoms::permission_denied(),
        PlatformError::IoError => atoms::io_error(),
        PlatformError::NotImplemented => atoms::not_implemented(),
    }
}

#[rustler::nif]
fn ping() -> Atom {
    atoms::pong()
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_bytes<'a>(env: Env<'a>, pid: i32, addr: u64, size: u64) -> Result<Binary<'a>, Atom> {
    match platform::read_bytes(pid, addr, size as usize) {
        Ok(buf) => match OwnedBinary::new(buf.len()) {
            Some(mut owned) => {
                owned.as_mut_slice().copy_from_slice(&buf);
                Ok(Binary::from_owned(owned, env))
            }
            None => Err(atoms::io_error()),
        },
        Err(e) => Err(err_atom(e)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_maps_nif(pid: i32) -> Result<Vec<MapEntry>, Atom> {
    platform::list_maps(pid).map_err(err_atom)
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_processes_nif() -> Result<Vec<(u32, String, String)>, Atom> {
    platform::list_processes().map_err(err_atom)
}

// ============================================================
// walk_collection NIF — exposes the Rust walker as a single
// fourth NIF (ADR-034 Revision 2026-04-25).
// ============================================================

/// One row in the `cards` list — `{arena_id, count}` 2-tuple on the
/// Elixir side.
#[derive(NifTuple)]
pub struct CardEntry {
    pub arena_id: i32,
    pub count: i32,
}

/// `wildcards: %{common, uncommon, rare, mythic}` map.
#[derive(NifMap)]
pub struct Wildcards {
    pub common: i32,
    pub uncommon: i32,
    pub rare: i32,
    pub mythic: i32,
}

/// One booster row — `{collation_id, count}` pair.
#[derive(NifMap)]
pub struct BoosterRow {
    pub collation_id: i32,
    pub count: i32,
}

/// Wire shape returned to Elixir on success — matches the contract
/// in `decisions/architecture/2026-04-22-034-memory-read-collection.md`
/// (Revision 2026-04-25). `vault_progress` is the live percentage
/// (0.0–100.0, e.g. `30.1`) — MTGA stores it as `System.Double`.
#[derive(NifMap)]
pub struct WalkSnapshot {
    pub cards: Vec<CardEntry>,
    pub wildcards: Wildcards,
    pub gold: i32,
    pub gems: i32,
    pub vault_progress: f64,
    pub boosters: Vec<BoosterRow>,
    pub build_hint: Option<String>,
    pub reader_version: String,
}

/// Wire-format mirror of [`walker::run::WalkError`]. Variants
/// carrying a class- or assembly-name parameter become tagged
/// tuples on the Elixir side, e.g.
/// `{:assembly_not_found, "Core"}`. Unit variants become bare atoms.
#[derive(NifTaggedEnum)]
pub enum WalkErrorWire {
    MonoDllNotFound,
    MonoDllReadFailed,
    RootDomainNotFound,
    AssemblyNotFound(String),
    ClassNotFound(String),
    ClassReadFailed(String),
    ChainFailed,
}

impl From<walker::run::WalkError> for WalkErrorWire {
    fn from(e: walker::run::WalkError) -> Self {
        use walker::run::WalkError as E;
        match e {
            E::MonoDllNotFound => Self::MonoDllNotFound,
            E::MonoDllReadFailed => Self::MonoDllReadFailed,
            E::RootDomainNotFound => Self::RootDomainNotFound,
            E::AssemblyNotFound(name) => Self::AssemblyNotFound(name.to_string()),
            E::ClassNotFound(name) => Self::ClassNotFound(name.to_string()),
            E::ClassReadFailed(name) => Self::ClassReadFailed(name.to_string()),
            E::ChainFailed => Self::ChainFailed,
        }
    }
}

/// Static identifier of the walker build, surfaced as `reader_version`
/// in [`WalkSnapshot`]. Bumped manually when the chain or offset
/// table changes in a way that would invalidate cached snapshots.
const READER_VERSION: &str = concat!("scry2-walker-", env!("CARGO_PKG_VERSION"));

fn snapshot_to_wire(snap: walker::run::Snapshot) -> WalkSnapshot {
    WalkSnapshot {
        cards: snap
            .entries
            .into_iter()
            .map(|e| CardEntry {
                arena_id: e.key,
                count: e.value,
            })
            .collect(),
        wildcards: Wildcards {
            common: snap.inventory.wc_common,
            uncommon: snap.inventory.wc_uncommon,
            rare: snap.inventory.wc_rare,
            mythic: snap.inventory.wc_mythic,
        },
        gold: snap.inventory.gold,
        gems: snap.inventory.gems,
        vault_progress: snap.inventory.vault_progress,
        boosters: snap
            .boosters
            .into_iter()
            .map(|b| BoosterRow {
                collation_id: b.collation_id,
                count: b.count,
            })
            .collect(),
        build_hint: snap.mtga_build_hint,
        reader_version: READER_VERSION.to_string(),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn walk_collection(pid: i32) -> Result<WalkSnapshot, WalkErrorWire> {
    let maps = platform::list_maps(pid).map_err(|_| WalkErrorWire::MonoDllReadFailed)?;
    let counter = AtomicU64::new(0);
    let inner = |addr: u64, len: usize| platform::read_bytes(pid, addr, len).ok();
    let read_mem = bounded(&counter, WALK_READ_BUDGET, inner);
    let snap = walker::run::walk_collection(&maps, read_mem, || {
        walker::build_hint::find_mtga_root(&maps)
            .and_then(|root| walker::build_hint::read_build_guid(&root))
    })
    .map_err(WalkErrorWire::from)?;
    Ok(snapshot_to_wire(snap))
}

/// Diagnostic NIF — list every `(assembly_name, class_name)` whose
/// class name contains `needle` (case-insensitive). Returned tuples
/// are `{assembly_name, class_name, class_addr}` so callers can
/// follow up with targeted reads.
///
/// Not exposed in the production behaviour; useful when a target
/// class can't be found by exact name and we need to discover what
/// it's actually called in a given MTGA build.
#[rustler::nif(schedule = "DirtyIo")]
fn walker_debug_classes_matching(
    pid: i32,
    needle: String,
) -> Result<Vec<(String, String, u64)>, Atom> {
    use walker::mono::MonoOffsets;
    let offsets = MonoOffsets::mtga_default();
    let maps = platform::list_maps(pid).map_err(err_atom)?;
    let counter = AtomicU64::new(0);
    let inner = |addr: u64, len: usize| platform::read_bytes(pid, addr, len).ok();
    let read_mem = bounded(&counter, WALK_READ_BUDGET, inner);

    let (mono_base, mono_bytes) =
        walker::run::read_mono_image(&maps, &read_mem).ok_or(atoms::io_error())?;
    let domain_addr = walker::domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(atoms::io_error())?;
    let pairs =
        walker::image_lookup::list_all_assembly_names_and_images(&offsets, domain_addr, read_mem)
            .ok_or(atoms::io_error())?;

    let needle_lower = needle.to_lowercase();
    let mut out = Vec::new();
    for (asm_name, image) in &pairs {
        if let Some(classes) = walker::class_lookup::list_all_classes(&offsets, *image, read_mem) {
            for (class_name, class_addr) in classes {
                if class_name.to_lowercase().contains(&needle_lower) {
                    out.push((asm_name.clone(), class_name, class_addr));
                }
            }
        }
    }
    Ok(out)
}

/// Diagnostic NIF — list every field on a class found by name in
/// any image, returning `{class_name, field_name, offset, is_static}`
/// for every field of every class whose name equals `class_name`.
#[rustler::nif(schedule = "DirtyIo")]
fn walker_debug_class_fields(
    pid: i32,
    class_name: String,
) -> Result<Vec<(String, String, i32, bool)>, Atom> {
    use walker::mono::{self as mono_mod, MonoOffsets, MONO_CLASS_FIELD_SIZE};
    let offsets = MonoOffsets::mtga_default();
    let maps = platform::list_maps(pid).map_err(err_atom)?;
    let counter = AtomicU64::new(0);
    let inner = |addr: u64, len: usize| platform::read_bytes(pid, addr, len).ok();
    let read_mem = bounded(&counter, WALK_READ_BUDGET, inner);

    let (mono_base, mono_bytes) =
        walker::run::read_mono_image(&maps, &read_mem).ok_or(atoms::io_error())?;
    let domain_addr = walker::domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(atoms::io_error())?;
    let images = walker::image_lookup::list_all_images(&offsets, domain_addr, read_mem)
        .ok_or(atoms::io_error())?;

    let mut out = Vec::new();
    for image in &images {
        let Some(classes) = walker::class_lookup::list_all_classes(&offsets, *image, read_mem)
        else {
            continue;
        };
        for (cname, class_addr) in classes {
            if cname != class_name {
                continue;
            }
            let Some(class_bytes) = read_mem(class_addr, walker::mono::CLASS_DEF_BLOB_LEN) else {
                continue;
            };
            let Some(fields_ptr) = mono_mod::class_fields_ptr(&offsets, &class_bytes, 0) else {
                continue;
            };
            let Some(field_count) = mono_mod::class_def_field_count(&offsets, &class_bytes, 0)
            else {
                continue;
            };
            for i in 0..(field_count as usize) {
                let entry_addr = fields_ptr + (i as u64) * (MONO_CLASS_FIELD_SIZE as u64);
                let Some(entry_buf) = read_mem(entry_addr, MONO_CLASS_FIELD_SIZE) else {
                    continue;
                };
                let Some(name_ptr) = mono_mod::field_name_ptr(&offsets, &entry_buf, 0) else {
                    continue;
                };
                let Some(name_buf) = read_mem(name_ptr, walker::limits::MAX_NAME_LEN) else {
                    continue;
                };
                let end = name_buf
                    .iter()
                    .position(|&b| b == 0)
                    .unwrap_or(name_buf.len());
                let fname = String::from_utf8_lossy(&name_buf[..end]).into_owned();
                let offset = mono_mod::field_offset_value(&offsets, &entry_buf, 0).unwrap_or(0);
                let type_ptr = mono_mod::field_type_ptr(&offsets, &entry_buf, 0).unwrap_or(0);
                let is_static = if type_ptr == 0 {
                    false
                } else {
                    read_mem(type_ptr, 12)
                        .and_then(|t| mono_mod::type_attrs(&offsets, &t, 0))
                        .map(mono_mod::attrs_is_static)
                        .unwrap_or(false)
                };
                out.push((cname.clone(), fname, offset, is_static));
            }
        }
    }
    Ok(out)
}

// ============================================================
// walk_match_info NIF — Chain 1 (rank, screen-name, commander)
// per decisions/research/2026-04-30-001-...md
// ============================================================

/// One PlayerInfo (local or opponent) for the wire format.
#[derive(NifMap)]
pub struct WirePlayerInfo {
    pub screen_name: Option<String>,
    pub seat_id: i32,
    pub team_id: i32,
    pub ranking_class: i32,
    pub ranking_tier: i32,
    pub mythic_percentile: i32,
    pub mythic_placement: i32,
    pub commander_grp_ids: Vec<i32>,
}

/// Wire shape returned to Elixir for a single MatchManager snapshot.
/// `nil` when there's no active match (PAPA._instance.MatchManager
/// is null).
#[derive(NifMap)]
pub struct WireMatchInfo {
    pub local: WirePlayerInfo,
    pub opponent: WirePlayerInfo,
    pub match_id: Option<String>,
    pub format: i32,
    pub variant: i32,
    pub session_type: i32,
    pub current_game_number: i32,
    pub match_state: i32,
    pub local_player_seat_id: i32,
    pub is_practice_game: bool,
    pub is_private_game: bool,
    pub reader_version: String,
}

fn match_info_to_wire(v: walker::match_info::MatchInfoValues) -> WireMatchInfo {
    WireMatchInfo {
        local: player_info_to_wire(v.local),
        opponent: player_info_to_wire(v.opponent),
        match_id: v.match_id,
        format: v.format,
        variant: v.variant,
        session_type: v.session_type,
        current_game_number: v.current_game_number,
        match_state: v.match_state,
        local_player_seat_id: v.local_player_seat_id,
        is_practice_game: v.is_practice_game,
        is_private_game: v.is_private_game,
        reader_version: READER_VERSION.to_string(),
    }
}

fn player_info_to_wire(p: walker::match_info::PlayerInfoValues) -> WirePlayerInfo {
    WirePlayerInfo {
        screen_name: p.screen_name,
        seat_id: p.seat_id,
        team_id: p.team_id,
        ranking_class: p.ranking_class,
        ranking_tier: p.ranking_tier,
        mythic_percentile: p.mythic_percentile,
        mythic_placement: p.mythic_placement,
        commander_grp_ids: p.commander_grp_ids,
    }
}

/// Read a single MatchManager snapshot from the target MTGA process.
///
/// Returns `{:ok, nil}` when MTGA is running but no match is active
/// (PAPA._instance.MatchManager is null). Returns `{:ok, %{...}}`
/// with the populated values when a match is in flight.
///
/// Live polling state machine (`Scry2.LiveState`, planned) calls this
/// every 250 ms while a match is active.
#[rustler::nif(schedule = "DirtyIo")]
fn walk_match_info(pid: i32) -> Result<Option<WireMatchInfo>, WalkErrorWire> {
    let maps = platform::list_maps(pid).map_err(|_| WalkErrorWire::MonoDllReadFailed)?;
    let counter = AtomicU64::new(0);
    let inner = |addr: u64, len: usize| platform::read_bytes(pid, addr, len).ok();
    let read_mem = bounded(&counter, WALK_READ_BUDGET, inner);
    let snap = walker::run::walk_match_info(&maps, read_mem).map_err(WalkErrorWire::from)?;
    Ok(snap.map(match_info_to_wire))
}

/// Diagnostic NIF — list every loaded assembly's
/// `{name, image_addr}`.
#[rustler::nif(schedule = "DirtyIo")]
fn walker_debug_list_assemblies(pid: i32) -> Result<Vec<(String, u64)>, Atom> {
    use walker::mono::MonoOffsets;
    let offsets = MonoOffsets::mtga_default();
    let maps = platform::list_maps(pid).map_err(err_atom)?;
    let counter = AtomicU64::new(0);
    let inner = |addr: u64, len: usize| platform::read_bytes(pid, addr, len).ok();
    let read_mem = bounded(&counter, WALK_READ_BUDGET, inner);

    let (mono_base, mono_bytes) =
        walker::run::read_mono_image(&maps, &read_mem).ok_or(atoms::io_error())?;
    let domain_addr = walker::domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(atoms::io_error())?;
    walker::image_lookup::list_all_assembly_names_and_images(&offsets, domain_addr, read_mem)
        .ok_or(atoms::io_error())
}

rustler::init!("Elixir.Scry2.MtgaMemory.Nif");
