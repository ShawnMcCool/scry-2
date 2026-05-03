//! Read MTGA's battle-pass / mastery-pass state from memory.
//!
//! Chain (verified spike 20, MTGA build Fri Apr 11 17:22:20 2025; see
//! `mtga-duress/experiments/spikes/spike20_mastery_pass/FINDING.md`):
//!
//! ```text
//! PAPA._instance                                  (resolved upstream)
//!   .<MasteryPassProvider>k__BackingField        -> SetMasteryDataProvider
//!     ._strategy                                  -> AwsSetMasteryStrategy
//!                                                    (polymorphic — assert class name)
//!       ._currentBpTrack                          -> ProgressionTrack
//!         .<Name>k__BackingField                  : MonoString * (e.g. "BattlePass_SOS")
//!         .<Levels>k__BackingField                : List<ProgressionTrackLevel>
//!         .<ExpirationTime>k__BackingField        : i64 .NET ticks
//!         .<CurrentLevel>k__BackingField          : i32 — tier
//!         .<CurrentLevelIndex>k__BackingField     : i32 — index into Levels
//!         .<MaxLevelIndex>k__BackingField         : i32 — season cap
//!         .<NumberOrbs>k__BackingField            : i32
//!
//! ProgressionTrackLevel (Levels[CurrentLevelIndex])
//!   .EXPProgressIfIsCurrent                       : i32 — XP toward next tier
//! ```
//!
//! Field names are looked up via [`super::field::find_field_by_name`];
//! offsets in the spike doc are diagnostic, not constants. The walker
//! survives field-position shifts between MTGA builds — only renames
//! break it.

use super::instance_field;
use super::limits::MAX_LIST_ELEMENTS;
use super::list_t;
use super::mono::{self, MonoOffsets};
use super::object;

/// Cap on the season-name `MonoString` read. MTGA names like
/// `"BattlePass_SOS"` are well under 64 chars; the cap bounds torn-read
/// damage.
const MAX_STRING_CHARS: usize = 64;

/// Cap on the class-name read used by the strategy polymorphism check.
/// Mono short class names are always under 256 bytes.
const MAX_CLASS_NAME_LEN: usize = 256;

/// `MonoArray<T>` element storage starts at `array_addr + 0x20` — the
/// flex `vector[]` field after the 32-byte header. Mirrors the constant
/// in `list_t` / `instance_field`.
const MONO_ARRAY_VECTOR_OFFSET: u64 = 0x20;

/// Snapshot of the player's current battle pass state.
///
/// All scalar fields default to `0` when the underlying field can't be
/// resolved. The whole struct is `None` when the chain itself is
/// unreachable (between seasons / mastery anchor not yet populated /
/// runtime is in a non-production strategy mode).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct MasteryInfo {
    pub tier: i32,
    pub xp_in_tier: i32,
    pub orbs: i32,
    pub season_name: Option<String>,
    pub expiration_time_ticks: Option<i64>,
}

const PAPA_ANCHOR_FIELD: &str = "<MasteryPassProvider>k__BackingField";
const STRATEGY_FIELD: &str = "_strategy";
const CURRENT_BP_TRACK_FIELD: &str = "_currentBpTrack";
const NAME_FIELD: &str = "<Name>k__BackingField";
const LEVELS_FIELD: &str = "<Levels>k__BackingField";
const EXPIRATION_TIME_FIELD: &str = "<ExpirationTime>k__BackingField";
const CURRENT_LEVEL_FIELD: &str = "<CurrentLevel>k__BackingField";
const CURRENT_LEVEL_INDEX_FIELD: &str = "<CurrentLevelIndex>k__BackingField";
const NUMBER_ORBS_FIELD: &str = "<NumberOrbs>k__BackingField";
const EXP_PROGRESS_FIELD: &str = "EXPProgressIfIsCurrent";

/// Production strategy class name on the `_strategy` field. MTGA also
/// has a `HarnessSetMasteryStrategy` for offline / test builds whose
/// field layout could differ — refuse to read at the wrong offsets.
const PRODUCTION_STRATEGY_CLASS: &str = "AwsSetMasteryStrategy";

/// Walk PAPA → SetMasteryDataProvider → AwsSetMasteryStrategy →
/// ProgressionTrack → fields, plus Levels[CurrentLevelIndex] for
/// XP-in-tier.
///
/// Returns `None` when the chain is unreachable at any hop (anchor
/// null, strategy null, current track null), or when the `_strategy`
/// runtime class isn't [`PRODUCTION_STRATEGY_CLASS`] (could be a test
/// fallback like `HarnessSetMasteryStrategy` — fail safe rather than
/// read at the wrong offsets).
pub fn from_papa_singleton<F>(
    offsets: &MonoOffsets,
    papa_singleton_addr: u64,
    papa_class_bytes: &[u8],
    read_mem: F,
) -> Option<MasteryInfo>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    // Hop 1: PAPA._instance → SetMasteryDataProvider
    let provider_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        PAPA_ANCHOR_FIELD,
        &read_mem,
    )?;
    let provider_class_bytes = object::read_runtime_class_bytes(provider_addr, &read_mem)?;

    // Hop 2: SetMasteryDataProvider._strategy → AwsSetMasteryStrategy
    let strategy_addr = object::read_instance_pointer(
        offsets,
        &provider_class_bytes,
        provider_addr,
        STRATEGY_FIELD,
        &read_mem,
    )?;
    // Verify the strategy is the production class. If MTGA is in a test/
    // fallback mode (HarnessSetMasteryStrategy), bail — its field layout
    // could differ.
    if !runtime_class_name_is(offsets, strategy_addr, PRODUCTION_STRATEGY_CLASS, &read_mem) {
        return None;
    }
    let strategy_class_bytes = object::read_runtime_class_bytes(strategy_addr, &read_mem)?;

    // Hop 3: AwsSetMasteryStrategy._currentBpTrack → ProgressionTrack
    let track_addr = object::read_instance_pointer(
        offsets,
        &strategy_class_bytes,
        strategy_addr,
        CURRENT_BP_TRACK_FIELD,
        &read_mem,
    )?;
    let track_class_bytes = object::read_runtime_class_bytes(track_addr, &read_mem)?;

    // Read scalars off ProgressionTrack.
    let tier = instance_field::read_instance_i32(
        offsets,
        &track_class_bytes,
        track_addr,
        CURRENT_LEVEL_FIELD,
        &read_mem,
    )
    .unwrap_or(0);

    let current_index = instance_field::read_instance_i32(
        offsets,
        &track_class_bytes,
        track_addr,
        CURRENT_LEVEL_INDEX_FIELD,
        &read_mem,
    )
    .unwrap_or(-1);

    let orbs = instance_field::read_instance_i32(
        offsets,
        &track_class_bytes,
        track_addr,
        NUMBER_ORBS_FIELD,
        &read_mem,
    )
    .unwrap_or(0);

    let season_name = instance_field::read_instance_string(
        offsets,
        &track_class_bytes,
        track_addr,
        NAME_FIELD,
        MAX_STRING_CHARS,
        &read_mem,
    );

    // ExpirationTime is i64 ticks. The field is stored as a 64-bit
    // signed integer in MTGA; we read it via the u64 helper since the
    // walker has no `read_instance_i64` and ticks are always positive
    // in practice (post-year-1 .NET epoch). The cast round-trips
    // losslessly for the entire positive range.
    let expiration_time_ticks = instance_field::read_instance_u64(
        offsets,
        &track_class_bytes,
        track_addr,
        EXPIRATION_TIME_FIELD,
        &read_mem,
    )
    .map(|v| v as i64);

    // XP-in-tier: deref Levels list, index to [current_index], read
    // EXPProgressIfIsCurrent on the element.
    let xp_in_tier = read_xp_in_tier(
        offsets,
        &track_class_bytes,
        track_addr,
        current_index,
        &read_mem,
    )
    .unwrap_or(0);

    Some(MasteryInfo {
        tier,
        xp_in_tier,
        orbs,
        season_name,
        expiration_time_ticks,
    })
}

/// Resolve `Levels[index]` and read `EXPProgressIfIsCurrent` off the
/// resulting `ProgressionTrackLevel` element.
///
/// Returns `None` when:
/// - `Levels` field doesn't resolve
/// - `index` is out of range or negative
/// - the element pointer is null
/// - the element's runtime class doesn't expose `EXPProgressIfIsCurrent`
fn read_xp_in_tier<F>(
    offsets: &MonoOffsets,
    track_class_bytes: &[u8],
    track_addr: u64,
    index: i32,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    if index < 0 {
        return None;
    }

    let levels_list_addr = object::read_instance_pointer(
        offsets,
        track_class_bytes,
        track_addr,
        LEVELS_FIELD,
        read_mem,
    )?;

    let levels_class_bytes = object::read_runtime_class_bytes(levels_list_addr, read_mem)?;

    let size = list_t::read_size(offsets, &levels_class_bytes, levels_list_addr, read_mem)?;
    if size <= 0 {
        return None;
    }
    if (index as i64) >= (size as i64) {
        return None;
    }
    // Bound the index against the list cap as a defensive guard against
    // torn `_size` reads — every other walker treats `MAX_LIST_ELEMENTS`
    // as the legitimate ceiling.
    if (index as usize) >= MAX_LIST_ELEMENTS {
        return None;
    }

    let items_ptr = list_t::read_items_ptr(offsets, &levels_class_bytes, levels_list_addr, read_mem)?;

    let element_addr = read_array_pointer_at(items_ptr, index as usize, read_mem)?;
    if element_addr == 0 {
        return None;
    }

    let element_class_bytes = object::read_runtime_class_bytes(element_addr, read_mem)?;
    instance_field::read_instance_i32(
        offsets,
        &element_class_bytes,
        element_addr,
        EXP_PROGRESS_FIELD,
        read_mem,
    )
}

/// Read a single pointer from the items array of a Mono `List<T>` /
/// `T[]`. `items_ptr` is the address returned by
/// [`list_t::read_items_ptr`]; element `i` lives at
/// `items_ptr + 0x20 + i * 8` — same indexing convention used by
/// `list_t::read_pointer_list` (which bulk-reads via
/// `mono_array::read_array_elements`).
fn read_array_pointer_at<F>(items_ptr: u64, index: usize, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let element_offset = (index as u64).checked_mul(8)?;
    let slot_addr = items_ptr
        .checked_add(MONO_ARRAY_VECTOR_OFFSET)?
        .checked_add(element_offset)?;
    let bytes = read_mem(slot_addr, 8)?;
    mono::read_u64(&bytes, 0, 0)
}

/// Resolve the runtime class name of `obj_addr` and check for an
/// exact match. Used to assert the polymorphic `_strategy` is the
/// production [`PRODUCTION_STRATEGY_CLASS`] and not a test fallback.
fn runtime_class_name_is<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    expected: &str,
    read_mem: &F,
) -> bool
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    match read_runtime_class_name(offsets, obj_addr, read_mem) {
        Some(actual) => actual == expected,
        None => false,
    }
}

/// Resolve `obj.vtable.klass.name` into a Rust `String`. `obj_addr`'s
/// vtable lookup mirrors [`object::read_runtime_class_bytes`]; the
/// difference is we want the class's NUL-terminated short name (at
/// `MonoClass.name`, offset `class_name`) rather than its field array.
fn read_runtime_class_name<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    read_mem: &F,
) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let class_bytes = object::read_runtime_class_bytes(obj_addr, read_mem)?;
    let name_ptr = mono::class_name_ptr(offsets, &class_bytes, 0)?;
    if name_ptr == 0 {
        return None;
    }
    let name_buf = read_mem(name_ptr, MAX_CLASS_NAME_LEN)?;
    let end = name_buf.iter().position(|&b| b == 0).unwrap_or(name_buf.len());
    Some(String::from_utf8_lossy(&name_buf[..end]).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_field_entry, make_type_block, FakeMem};

    /// Field descriptor for fixture builders: name, byte offset on the
    /// declaring class.
    type FieldSpec<'a> = (&'a str, i32);

    /// Build a class def whose `MonoClassField[]` lives at `fields_addr`.
    /// Each field gets its own name-string and `MonoType` block, both
    /// stamped into `mem` at deterministic addresses derived from
    /// `fields_addr`.
    fn install_class_fields(
        mem: &mut FakeMem,
        fields_addr: u64,
        fields: &[FieldSpec<'_>],
    ) -> Vec<u8> {
        let names_base = fields_addr + 0x1_0000;
        let types_base = fields_addr + 0x2_0000;
        let mut entry_blob = Vec::with_capacity(fields.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset)) in fields.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, 0, *offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_addr, entry_blob);
        make_class_def(fields_addr, fields.len() as u32)
    }

    /// Stamp a `MonoClassDef` blob into `mem` at `class_addr`, then
    /// install a vtable pointing at it. Returns the vtable address —
    /// stamp it into the object's first 8 bytes so
    /// `read_runtime_class_bytes` resolves to `class_bytes`.
    fn install_class_at(
        mem: &mut FakeMem,
        class_addr: u64,
        vtable_addr: u64,
        class_bytes: Vec<u8>,
    ) {
        mem.add(class_addr, class_bytes);
        let mut vt = vec![0u8; 0x10];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
    }

    /// Stamp `MonoClass.name` to `class_name` inside an *already-installed*
    /// class blob at `class_addr`. Uses `replace` to overwrite the existing
    /// block instead of tripping the overlap guard.
    ///
    /// Returns `Err` if the caller forgot to install the class blob first
    /// — the test harness uses `?` to propagate that error rather than
    /// panicking via `expect`.
    fn stamp_class_name(
        mem: &mut FakeMem,
        class_addr: u64,
        name_addr: u64,
        class_name: &str,
    ) -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let existing = mem
            .read(class_addr, super::super::mono::CLASS_DEF_BLOB_LEN)
            .ok_or_else(|| format!("class blob not installed at {class_addr:#x}"))?;
        let mut blob = existing;
        if blob.len() < super::super::mono::CLASS_DEF_BLOB_LEN {
            blob.resize(super::super::mono::CLASS_DEF_BLOB_LEN, 0);
        }
        blob[offsets.class_name..offsets.class_name + 8]
            .copy_from_slice(&name_addr.to_le_bytes());
        mem.replace(class_addr, blob);

        let mut name_bytes = class_name.as_bytes().to_vec();
        name_bytes.push(0);
        mem.add(name_addr, name_bytes);
        Ok(())
    }

    /// Build a MonoString at `addr` containing `s` (UTF-16 LE).
    fn install_mono_string(mem: &mut FakeMem, addr: u64, s: &str) {
        let utf16: Vec<u16> = s.encode_utf16().collect();
        let mut hdr = vec![0u8; 0x14];
        hdr[0x10..0x14].copy_from_slice(&(utf16.len() as i32).to_le_bytes());
        mem.add(addr, hdr);
        let mut chars = Vec::with_capacity(utf16.len() * 2);
        for u in &utf16 {
            chars.extend_from_slice(&u.to_le_bytes());
        }
        mem.add(addr + 0x14, chars);
    }

    /// Stamp an i32 at `offset` in `payload`.
    fn stamp_i32(payload: &mut [u8], offset: i32, value: i32) {
        let off = offset as usize;
        payload[off..off + 4].copy_from_slice(&value.to_le_bytes());
    }

    /// Stamp a u64 at `offset` in `payload`.
    fn stamp_u64(payload: &mut [u8], offset: i32, value: u64) {
        let off = offset as usize;
        payload[off..off + 8].copy_from_slice(&value.to_le_bytes());
    }

    /// Stamp a pointer at `offset` in `payload`.
    fn stamp_ptr(payload: &mut [u8], offset: i32, ptr: u64) {
        let off = offset as usize;
        payload[off..off + 8].copy_from_slice(&ptr.to_le_bytes());
    }

    /// Address allocator for fixture construction.
    ///
    /// Address layout note: `install_class_fields` derives its names and
    /// types regions from the supplied `fields_addr` as
    /// `fields_addr + 0x1_0000` and `fields_addr + 0x2_0000`, so any two
    /// "fields" addresses must be at least `0x3_0000` apart. Each
    /// chain-hop region therefore reserves 64 MiB (`0x0400_0000`) and
    /// each fields slot inside that region is pinned at the same
    /// per-region offset.
    struct AddrPlan;

    impl AddrPlan {
        // Region 0: PAPA — only PAPA singleton + PAPA class fields.
        const PAPA_OBJECT: u64 = 0x0100_0000;
        const PAPA_CLASS_FIELDS: u64 = 0x0110_0000;

        // Region 1: SetMasteryDataProvider.
        const PROVIDER_OBJECT: u64 = 0x0500_0000;
        const PROVIDER_VTABLE: u64 = 0x0510_0000;
        const PROVIDER_CLASS: u64 = 0x0520_0000;
        const PROVIDER_CLASS_FIELDS: u64 = 0x0530_0000;

        // Region 2: AwsSetMasteryStrategy.
        const STRATEGY_OBJECT: u64 = 0x0900_0000;
        const STRATEGY_VTABLE: u64 = 0x0910_0000;
        const STRATEGY_CLASS: u64 = 0x0920_0000;
        const STRATEGY_CLASS_FIELDS: u64 = 0x0930_0000;
        const STRATEGY_CLASS_NAME: u64 = 0x09f0_0000;

        // Region 3: ProgressionTrack.
        const TRACK_OBJECT: u64 = 0x0d00_0000;
        const TRACK_VTABLE: u64 = 0x0d10_0000;
        const TRACK_CLASS: u64 = 0x0d20_0000;
        const TRACK_CLASS_FIELDS: u64 = 0x0d30_0000;
        const TRACK_NAME_STRING: u64 = 0x0df0_0000;

        // Region 4: List<ProgressionTrackLevel>.
        const LEVELS_LIST_OBJECT: u64 = 0x1100_0000;
        const LEVELS_LIST_VTABLE: u64 = 0x1110_0000;
        const LEVELS_LIST_CLASS: u64 = 0x1120_0000;
        const LEVELS_LIST_CLASS_FIELDS: u64 = 0x1130_0000;
        const LEVELS_ITEMS_ARRAY: u64 = 0x11f0_0000;

        // Region 5: ProgressionTrackLevel elements + their shared class.
        const ELEMENT_OBJECT_BASE: u64 = 0x1500_0000;
        const ELEMENT_VTABLE: u64 = 0x18f0_0000;
        const ELEMENT_CLASS: u64 = 0x1900_0000;
        const ELEMENT_CLASS_FIELDS: u64 = 0x1910_0000;

        fn element_addr(index: usize) -> u64 {
            // 0x1000 (= 4 KiB) per element is plenty for one 0x100-byte
            // payload and avoids overlap with neighbouring elements.
            Self::ELEMENT_OBJECT_BASE + (index as u64) * 0x1000
        }
    }

    /// Build a complete happy-path chain: PAPA singleton holds anchor
    /// to provider; provider holds `_strategy` to a strategy whose
    /// runtime class name is "AwsSetMasteryStrategy"; strategy holds
    /// `_currentBpTrack` to a ProgressionTrack whose `Levels` list has
    /// `levels_count` elements; element at `current_index` carries
    /// `xp_in_tier`.
    struct ChainBuilder {
        mem: FakeMem,
        offsets: MonoOffsets,
    }

    struct ChainConfig<'a> {
        tier: i32,
        current_index: i32,
        orbs: i32,
        season_name: Option<&'a str>,
        expiration_ticks: u64,
        levels_count: i32,
        xp_in_tier: i32,
        strategy_class_name: &'a str,
        current_bp_track_addr: u64,
        levels_list_addr: u64,
        season_name_ptr: u64,
    }

    impl<'a> Default for ChainConfig<'a> {
        fn default() -> Self {
            Self {
                tier: 17,
                current_index: 16,
                orbs: 0,
                season_name: Some("BattlePass_SOS"),
                expiration_ticks: 639_178_128_000_000_000,
                levels_count: 60,
                xp_in_tier: 250,
                strategy_class_name: PRODUCTION_STRATEGY_CLASS,
                current_bp_track_addr: AddrPlan::TRACK_OBJECT,
                levels_list_addr: AddrPlan::LEVELS_LIST_OBJECT,
                season_name_ptr: AddrPlan::TRACK_NAME_STRING,
            }
        }
    }

    impl ChainBuilder {
        fn new() -> Self {
            Self {
                mem: FakeMem::default(),
                offsets: MonoOffsets::mtga_default(),
            }
        }

        /// Wire up the entire chain per `cfg` and return the addresses
        /// the test needs (PAPA singleton + class bytes).
        fn build(
            mut self,
            cfg: ChainConfig<'_>,
        ) -> Result<(FakeMem, MonoOffsets, u64, Vec<u8>), String> {
            // ── PAPA class: one field "<MasteryPassProvider>k__BackingField"
            //    at +0x10 holding the provider object pointer.
            let papa_anchor_offset = 0x10i32;
            let papa_class_bytes = install_class_fields(
                &mut self.mem,
                AddrPlan::PAPA_CLASS_FIELDS,
                &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
            );
            let mut papa_payload = vec![0u8; 0x40];
            stamp_ptr(&mut papa_payload, papa_anchor_offset, AddrPlan::PROVIDER_OBJECT);
            self.mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

            // ── Provider class: one field "_strategy" at +0x10.
            let strategy_field_offset = 0x10i32;
            let provider_class_bytes = install_class_fields(
                &mut self.mem,
                AddrPlan::PROVIDER_CLASS_FIELDS,
                &[(STRATEGY_FIELD, strategy_field_offset)],
            );
            install_class_at(
                &mut self.mem,
                AddrPlan::PROVIDER_CLASS,
                AddrPlan::PROVIDER_VTABLE,
                provider_class_bytes,
            );
            let mut provider_payload = vec![0u8; 0x40];
            stamp_ptr(
                &mut provider_payload,
                0,
                AddrPlan::PROVIDER_VTABLE,
            );
            stamp_ptr(
                &mut provider_payload,
                strategy_field_offset,
                AddrPlan::STRATEGY_OBJECT,
            );
            self.mem.add(AddrPlan::PROVIDER_OBJECT, provider_payload);

            // ── Strategy class: one field "_currentBpTrack" at +0x10
            //    plus a class-name string for the polymorphism check.
            let track_field_offset = 0x10i32;
            let strategy_class_bytes = install_class_fields(
                &mut self.mem,
                AddrPlan::STRATEGY_CLASS_FIELDS,
                &[(CURRENT_BP_TRACK_FIELD, track_field_offset)],
            );
            install_class_at(
                &mut self.mem,
                AddrPlan::STRATEGY_CLASS,
                AddrPlan::STRATEGY_VTABLE,
                strategy_class_bytes,
            );
            stamp_class_name(
                &mut self.mem,
                AddrPlan::STRATEGY_CLASS,
                AddrPlan::STRATEGY_CLASS_NAME,
                cfg.strategy_class_name,
            )?;
            let mut strategy_payload = vec![0u8; 0x40];
            stamp_ptr(&mut strategy_payload, 0, AddrPlan::STRATEGY_VTABLE);
            stamp_ptr(
                &mut strategy_payload,
                track_field_offset,
                cfg.current_bp_track_addr,
            );
            self.mem.add(AddrPlan::STRATEGY_OBJECT, strategy_payload);

            // ── ProgressionTrack class: Name @ +0x10, Levels @ +0x20,
            //    ExpirationTime @ +0x50, CurrentLevel @ +0x60,
            //    CurrentLevelIndex @ +0x64, NumberOrbs @ +0x70.
            let name_offset = 0x10i32;
            let levels_offset = 0x20i32;
            let expiration_offset = 0x50i32;
            let current_level_offset = 0x60i32;
            let current_level_index_offset = 0x64i32;
            let number_orbs_offset = 0x70i32;
            let track_class_bytes = install_class_fields(
                &mut self.mem,
                AddrPlan::TRACK_CLASS_FIELDS,
                &[
                    (NAME_FIELD, name_offset),
                    (LEVELS_FIELD, levels_offset),
                    (EXPIRATION_TIME_FIELD, expiration_offset),
                    (CURRENT_LEVEL_FIELD, current_level_offset),
                    (CURRENT_LEVEL_INDEX_FIELD, current_level_index_offset),
                    (NUMBER_ORBS_FIELD, number_orbs_offset),
                ],
            );
            install_class_at(
                &mut self.mem,
                AddrPlan::TRACK_CLASS,
                AddrPlan::TRACK_VTABLE,
                track_class_bytes,
            );
            let mut track_payload = vec![0u8; 0x100];
            stamp_ptr(&mut track_payload, 0, AddrPlan::TRACK_VTABLE);
            stamp_ptr(&mut track_payload, name_offset, cfg.season_name_ptr);
            stamp_ptr(&mut track_payload, levels_offset, cfg.levels_list_addr);
            stamp_u64(&mut track_payload, expiration_offset, cfg.expiration_ticks);
            stamp_i32(&mut track_payload, current_level_offset, cfg.tier);
            stamp_i32(
                &mut track_payload,
                current_level_index_offset,
                cfg.current_index,
            );
            stamp_i32(&mut track_payload, number_orbs_offset, cfg.orbs);
            self.mem.add(cfg.current_bp_track_addr, track_payload);

            if let Some(name) = cfg.season_name {
                install_mono_string(&mut self.mem, cfg.season_name_ptr, name);
            }

            // ── Levels list: List<T> with `_items @ 0x10`, `_size @ 0x18`.
            if cfg.levels_list_addr != 0 {
                self.install_levels_list(
                    cfg.levels_list_addr,
                    cfg.levels_count,
                    cfg.current_index,
                    cfg.xp_in_tier,
                );
            }

            Ok((
                self.mem,
                self.offsets,
                AddrPlan::PAPA_OBJECT,
                papa_class_bytes,
            ))
        }

        fn install_levels_list(
            &mut self,
            list_addr: u64,
            size: i32,
            current_index: i32,
            xp_in_tier: i32,
        ) {
            // List<T> class layout used by `list_t`: `_items` @ 0x10,
            // `_size` @ 0x18.
            let list_class_bytes = install_class_fields(
                &mut self.mem,
                AddrPlan::LEVELS_LIST_CLASS_FIELDS,
                &[("_items", 0x10), ("_size", 0x18)],
            );
            install_class_at(
                &mut self.mem,
                AddrPlan::LEVELS_LIST_CLASS,
                AddrPlan::LEVELS_LIST_VTABLE,
                list_class_bytes,
            );

            let mut list_payload = vec![0u8; 0x30];
            stamp_ptr(&mut list_payload, 0, AddrPlan::LEVELS_LIST_VTABLE);
            stamp_ptr(&mut list_payload, 0x10, AddrPlan::LEVELS_ITEMS_ARRAY);
            stamp_i32(&mut list_payload, 0x18, size);
            self.mem.add(list_addr, list_payload);

            // Element class shared by every Levels[i] — one field
            // "EXPProgressIfIsCurrent" at +0x30.
            let element_class_bytes = install_class_fields(
                &mut self.mem,
                AddrPlan::ELEMENT_CLASS_FIELDS,
                &[(EXP_PROGRESS_FIELD, 0x30)],
            );
            install_class_at(
                &mut self.mem,
                AddrPlan::ELEMENT_CLASS,
                AddrPlan::ELEMENT_VTABLE,
                element_class_bytes,
            );

            // Items array: `MONO_ARRAY_VECTOR_OFFSET (0x20)` from the
            // array base, then 8-byte pointer slots. Only the slot at
            // `current_index` needs a real element pointer; others can
            // stay null.
            let array_size = (size.max(0) as u64) * 8;
            let mut array_storage = vec![0u8; (MONO_ARRAY_VECTOR_OFFSET + array_size) as usize];
            // The array header itself can stay zeros; `list_t::read_size`
            // gets size from the list, not the array header.
            if current_index >= 0 && current_index < size {
                let element_addr = AddrPlan::element_addr(current_index as usize);
                let slot_off = (MONO_ARRAY_VECTOR_OFFSET + (current_index as u64) * 8) as usize;
                array_storage[slot_off..slot_off + 8]
                    .copy_from_slice(&element_addr.to_le_bytes());

                let mut element_payload = vec![0u8; 0x40];
                stamp_ptr(&mut element_payload, 0, AddrPlan::ELEMENT_VTABLE);
                stamp_i32(&mut element_payload, 0x30, xp_in_tier);
                self.mem.add(element_addr, element_payload);
            }
            self.mem.add(AddrPlan::LEVELS_ITEMS_ARRAY, array_storage);
        }
    }

    #[test]
    fn reads_full_chain_happy_path() -> Result<(), String> {
        let (mem, offsets, papa_addr, papa_class_bytes) =
            ChainBuilder::new().build(ChainConfig::default())?;

        let info = from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        })
        .ok_or("happy path must yield a snapshot")?;

        assert_eq!(info.tier, 17);
        assert_eq!(info.xp_in_tier, 250);
        assert_eq!(info.orbs, 0);
        assert_eq!(info.season_name.as_deref(), Some("BattlePass_SOS"));
        assert_eq!(info.expiration_time_ticks, Some(639_178_128_000_000_000));
        Ok(())
    }

    #[test]
    fn returns_none_when_strategy_is_harness_class() -> Result<(), String> {
        let (mem, offsets, papa_addr, papa_class_bytes) = ChainBuilder::new().build(ChainConfig {
            strategy_class_name: "HarnessSetMasteryStrategy",
            ..ChainConfig::default()
        })?;

        let info = from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        });
        assert!(
            info.is_none(),
            "non-Aws strategy must bail rather than read at the wrong layout"
        );
        Ok(())
    }

    #[test]
    fn returns_none_when_current_bp_track_is_null() -> Result<(), String> {
        let (mem, offsets, papa_addr, papa_class_bytes) = ChainBuilder::new().build(ChainConfig {
            current_bp_track_addr: 0,
            ..ChainConfig::default()
        })?;

        let info = from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        });
        assert!(info.is_none(), "null _currentBpTrack must short-circuit");
        Ok(())
    }

    #[test]
    fn out_of_range_current_index_yields_zero_xp_with_other_fields_intact() -> Result<(), String> {
        let (mem, offsets, papa_addr, papa_class_bytes) = ChainBuilder::new().build(ChainConfig {
            current_index: 99,
            levels_count: 60,
            ..ChainConfig::default()
        })?;

        let info = from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        })
        .ok_or("out-of-range index still yields a snapshot")?;

        assert_eq!(info.xp_in_tier, 0, "must default to 0 on out-of-range index");
        assert_eq!(info.tier, 17);
        assert_eq!(info.orbs, 0);
        assert_eq!(info.season_name.as_deref(), Some("BattlePass_SOS"));
        assert_eq!(info.expiration_time_ticks, Some(639_178_128_000_000_000));
        Ok(())
    }

    #[test]
    fn null_season_name_yields_none_with_other_fields_intact() -> Result<(), String> {
        let (mem, offsets, papa_addr, papa_class_bytes) = ChainBuilder::new().build(ChainConfig {
            season_name: None,       // skip MonoString install
            season_name_ptr: 0,      // and null the slot in the track
            ..ChainConfig::default()
        })?;

        let info = from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        })
        .ok_or("null name still yields a snapshot")?;

        assert_eq!(info.season_name, None);
        assert_eq!(info.tier, 17);
        assert_eq!(info.xp_in_tier, 250);
        assert_eq!(info.orbs, 0);
        assert_eq!(info.expiration_time_ticks, Some(639_178_128_000_000_000));
        Ok(())
    }
}
