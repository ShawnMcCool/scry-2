//! Read MTGA's `MatchManager` rank, screen-name, and commander info.
//!
//! Chain (verified against MTGA build `Fri Apr 11 17:22:20 2025`,
//! see `mtga-duress/experiments/spikes/spike16_match_manager/FINDING.md`):
//!
//! ```text
//! PAPA._instance                                  (existing inventory anchor)
//!   .MatchManager                                 (instance field)
//!     .LocalPlayerInfo                            -> PlayerInfo
//!     .OpponentInfo                               -> PlayerInfo
//!     .MatchID                                    -> MonoString *
//!     .Format / .Variant / .SessionType           : i32 enums
//!     .CurrentGameNumber / .MatchState            : i32
//!     .IsPracticeGame / .IsPrivateGame            : bool
//!
//! PlayerInfo                                       (same class for both)
//!   ._screenName                                  -> MonoString *
//!   .SeatId / .TeamId                             : i32
//!   .RankingClass                                 : i32 enum [None, Bronze, ..., Mythic]
//!   .RankingTier                                  : i32 (1..=4 within class)
//!   .MythicPercentile                             : i32 (probable; verify on Mythic player)
//!   .MythicPlacement                              : i32
//!   .CommanderGrpIds                              -> List<i32>
//! ```
//!
//! Field names are resolved dynamically via [`super::field::find_by_name`]
//! — the verified offsets in the FINDING.md are diagnostic, not constants.
//! This makes the walker resilient to field-position shifts between MTGA
//! builds (only field-name changes break it).
//!
//! ## Tear-down behaviour — important
//!
//! After a match completes, MTGA resets both `LocalPlayerInfo` and
//! `OpponentInfo` to placeholder defaults: `_screenName` reverts to
//! `"Local Player"` / `"Opponent"`, all rank ints zero. The caller
//! must read **during** the match — typically at `MatchCreated` log
//! event time and again at end-of-match-but-before-tear-down.
//! See `Scry2.LiveState` (planned) for the polling architecture.

use super::field::{self, ResolvedField};
use super::mono::{self, MonoOffsets};

/// Snapshot of the live MatchManager state at one moment.
///
/// All scalar fields default to 0 / empty / None when the underlying
/// pointer is null or the field can't be resolved — callers compare
/// against placeholders (e.g. `screen_name == "Opponent"`) to detect
/// the post-tear-down state described in the module docs.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct MatchInfoValues {
    pub local: PlayerInfoValues,
    pub opponent: PlayerInfoValues,
    pub match_id: Option<String>,
    pub format: i32,
    pub variant: i32,
    pub session_type: i32,
    pub current_game_number: i32,
    pub match_state: i32,
    pub local_player_seat_id: i32,
    pub is_practice_game: bool,
    pub is_private_game: bool,
}

/// Snapshot of one PlayerInfo (used for both local and opponent — same class).
///
/// `MythicPercentile` is read as `i32` pending verification against a
/// Mythic-tier player (spike 16 only saw Diamond, where the value is 0
/// regardless of byte width).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PlayerInfoValues {
    pub screen_name: Option<String>,
    pub seat_id: i32,
    pub team_id: i32,
    pub ranking_class: i32,
    pub ranking_tier: i32,
    pub mythic_percentile: i32,
    pub mythic_placement: i32,
    pub commander_grp_ids: Vec<i32>,
}

/// Field names resolved on `PAPA` (only `MatchManager`; `_instance` is
/// already handled upstream by the inventory chain).
pub const PAPA_MATCH_MANAGER_FIELD: &str = "MatchManager";

/// Field names resolved on `MatchManager`.
pub const MATCH_MANAGER_FIELDS: [&str; 11] = [
    "LocalPlayerInfo",
    "OpponentInfo",
    "MatchID",
    "Format",
    "Variant",
    "SessionType",
    "CurrentGameNumber",
    "MatchState",
    "LocalPlayerSeatId",
    "IsPracticeGame",
    "IsPrivateGame",
];

/// Field names resolved on `PlayerInfo` (same class for both local
/// and opponent).
pub const PLAYER_INFO_FIELDS: [&str; 8] = [
    "_screenName",
    "SeatId",
    "TeamId",
    "RankingClass",
    "RankingTier",
    "MythicPercentile",
    "MythicPlacement",
    "CommanderGrpIds",
];

/// Read MatchManager + both PlayerInfos starting from a resolved PAPA
/// singleton address.
///
/// Returns `None` if `MatchManager` itself can't be resolved or its
/// pointer is null. Returns `Some(_)` even when individual sub-fields
/// fail to resolve — those degrade to default values (`""`, `0`).
/// Callers can detect "no active match" by comparing
/// `result.opponent.screen_name` against the placeholder `"Opponent"`.
///
/// Required inputs:
/// - `papa_singleton_addr` — PAPA singleton object address (already
///   resolved by the inventory chain via vtable static-storage).
/// - `papa_class_bytes` — `MonoClassDef` bytes of the PAPA class
///   (covers the MatchManager backing field).
/// - `read_mem(addr, len)` — remote-memory reader closure.
pub fn from_papa_singleton<F>(
    offsets: &MonoOffsets,
    papa_singleton_addr: u64,
    papa_class_bytes: &[u8],
    read_mem: F,
) -> Option<MatchInfoValues>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let mm_addr = read_instance_pointer(
        offsets,
        papa_class_bytes,
        0,
        papa_singleton_addr,
        PAPA_MATCH_MANAGER_FIELD,
        &read_mem,
    )?;

    let mm_class_bytes = read_object_class_def(mm_addr, &read_mem)?;

    let mut values = MatchInfoValues::default();

    if let Some(local_addr) = read_instance_pointer(
        offsets,
        &mm_class_bytes,
        0,
        mm_addr,
        "LocalPlayerInfo",
        &read_mem,
    ) {
        if let Some(class_bytes) = read_object_class_def(local_addr, &read_mem) {
            values.local = read_player_info(offsets, &class_bytes, local_addr, &read_mem);
        }
    }

    if let Some(opp_addr) = read_instance_pointer(
        offsets,
        &mm_class_bytes,
        0,
        mm_addr,
        "OpponentInfo",
        &read_mem,
    ) {
        if let Some(class_bytes) = read_object_class_def(opp_addr, &read_mem) {
            values.opponent = read_player_info(offsets, &class_bytes, opp_addr, &read_mem);
        }
    }

    values.match_id = read_string_field(offsets, &mm_class_bytes, mm_addr, "MatchID", &read_mem);
    values.format = read_i32_field(offsets, &mm_class_bytes, mm_addr, "Format", &read_mem);
    values.variant = read_i32_field(offsets, &mm_class_bytes, mm_addr, "Variant", &read_mem);
    values.session_type =
        read_i32_field(offsets, &mm_class_bytes, mm_addr, "SessionType", &read_mem);
    values.current_game_number = read_i32_field(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "CurrentGameNumber",
        &read_mem,
    );
    values.match_state =
        read_i32_field(offsets, &mm_class_bytes, mm_addr, "MatchState", &read_mem);
    values.local_player_seat_id = read_i32_field(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "LocalPlayerSeatId",
        &read_mem,
    );
    values.is_practice_game =
        read_bool_field(offsets, &mm_class_bytes, mm_addr, "IsPracticeGame", &read_mem);
    values.is_private_game =
        read_bool_field(offsets, &mm_class_bytes, mm_addr, "IsPrivateGame", &read_mem);

    Some(values)
}

/// Read every primitive + screen-name + commander list off a resolved
/// PlayerInfo object.
fn read_player_info<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    read_mem: &F,
) -> PlayerInfoValues
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    PlayerInfoValues {
        screen_name: read_string_field(offsets, class_bytes, object_addr, "_screenName", read_mem),
        seat_id: read_i32_field(offsets, class_bytes, object_addr, "SeatId", read_mem),
        team_id: read_i32_field(offsets, class_bytes, object_addr, "TeamId", read_mem),
        ranking_class: read_i32_field(offsets, class_bytes, object_addr, "RankingClass", read_mem),
        ranking_tier: read_i32_field(offsets, class_bytes, object_addr, "RankingTier", read_mem),
        mythic_percentile: read_i32_field(
            offsets,
            class_bytes,
            object_addr,
            "MythicPercentile",
            read_mem,
        ),
        mythic_placement: read_i32_field(
            offsets,
            class_bytes,
            object_addr,
            "MythicPlacement",
            read_mem,
        ),
        commander_grp_ids: read_int_list_field(
            offsets,
            class_bytes,
            object_addr,
            "CommanderGrpIds",
            read_mem,
        ),
    }
}

// ─── primitive readers ──────────────────────────────────────────────

fn read_instance_pointer<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    class_base: usize,
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved: ResolvedField =
        field::find_by_name(offsets, class_bytes, class_base, field_name, read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let addr = object_addr.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(addr, 8)?;
    let ptr = mono::read_u64(&bytes, 0, 0)?;
    if ptr == 0 {
        None
    } else {
        Some(ptr)
    }
}

fn read_i32_field<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> i32
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let Some(resolved) = field::find_by_name(offsets, class_bytes, 0, field_name, read_mem) else {
        return 0;
    };
    if resolved.is_static || resolved.offset < 0 {
        return 0;
    }
    let Some(addr) = object_addr.checked_add(resolved.offset as u64) else {
        return 0;
    };
    let Some(bytes) = read_mem(addr, 4) else {
        return 0;
    };
    mono::read_u32(&bytes, 0, 0).map(|v| v as i32).unwrap_or(0)
}

fn read_bool_field<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> bool
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let Some(resolved) = field::find_by_name(offsets, class_bytes, 0, field_name, read_mem) else {
        return false;
    };
    if resolved.is_static || resolved.offset < 0 {
        return false;
    }
    let Some(addr) = object_addr.checked_add(resolved.offset as u64) else {
        return false;
    };
    let Some(bytes) = read_mem(addr, 1) else {
        return false;
    };
    bytes.first().map(|b| *b != 0).unwrap_or(false)
}

/// Read a `MonoString *` field and decode its UTF-16 contents.
///
/// `MonoString` layout: `vtable(8) + sync(8) + length:i32 + chars[length]`
/// (UTF-16 LE).
fn read_string_field<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved = field::find_by_name(offsets, class_bytes, 0, field_name, read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let slot_addr = object_addr.checked_add(resolved.offset as u64)?;
    let str_ptr = read_mem(slot_addr, 8).and_then(|b| mono::read_u64(&b, 0, 0))?;
    if str_ptr == 0 {
        return None;
    }
    let header = read_mem(str_ptr, 0x14)?;
    if header.len() < 0x14 {
        return None;
    }
    let length =
        i32::from_le_bytes([header[0x10], header[0x11], header[0x12], header[0x13]]).max(0)
            as usize;
    if length == 0 {
        return Some(String::new());
    }
    if length > 1024 {
        return None; // sanity guard
    }
    let chars_bytes = read_mem(str_ptr + 0x14, length * 2)?;
    let utf16: Vec<u16> = chars_bytes
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16(&utf16).ok()
}

/// Read a `List<int>` field — Mono `List<T>` layout is
/// `T[] _items + i32 _size + i32 _version`. The backing
/// `MonoArray<int32>` element storage starts at `array_base + 0x20`.
fn read_int_list_field<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Vec<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let Some(resolved) = field::find_by_name(offsets, class_bytes, 0, field_name, read_mem) else {
        return Vec::new();
    };
    if resolved.is_static || resolved.offset < 0 {
        return Vec::new();
    }
    let Some(slot_addr) = object_addr.checked_add(resolved.offset as u64) else {
        return Vec::new();
    };
    let Some(list_ptr) = read_mem(slot_addr, 8).and_then(|b| mono::read_u64(&b, 0, 0)) else {
        return Vec::new();
    };
    if list_ptr == 0 {
        return Vec::new();
    }
    // Resolve _items + _size on the List<T> object via its runtime
    // class. Don't trust hardcoded offsets — they vary by closed
    // generic instantiation.
    let Some(list_class_bytes) = read_object_class_def(list_ptr, read_mem) else {
        return Vec::new();
    };
    let Some(items_ptr) = read_instance_pointer(
        offsets,
        &list_class_bytes,
        0,
        list_ptr,
        "_items",
        read_mem,
    ) else {
        return Vec::new();
    };
    let size = read_i32_field(offsets, &list_class_bytes, list_ptr, "_size", read_mem);
    if size <= 0 {
        return Vec::new();
    }
    let count = (size as usize).min(1024); // sanity cap
    let Some(elements) = read_mem(items_ptr + 0x20, count * 4) else {
        return Vec::new();
    };
    elements
        .chunks_exact(4)
        .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// Read `obj.vtable.klass` and pull a class-def-sized blob.
///
/// `MonoObject.vtable` and `MonoVTable.klass` both live at offset 0
/// of their respective structs.
fn read_object_class_def<F>(obj_addr: u64, read_mem: &F) -> Option<Vec<u8>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable_addr = read_mem(obj_addr, 8).and_then(|b| mono::read_u64(&b, 0, 0))?;
    if vtable_addr == 0 {
        return None;
    }
    let klass_addr = read_mem(vtable_addr, 8).and_then(|b| mono::read_u64(&b, 0, 0))?;
    if klass_addr == 0 {
        return None;
    }
    // Same blob length the rest of the walker uses.
    read_mem(klass_addr, super::run::CLASS_DEF_BLOB_LEN)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;

    /// FakeMem fixture identical in shape to the one used by every
    /// other walker test module.
    #[derive(Default)]
    struct FakeMem {
        blocks: Vec<(u64, Vec<u8>)>,
    }

    impl FakeMem {
        fn add(&mut self, addr: u64, bytes: Vec<u8>) {
            self.blocks.push((addr, bytes));
        }
        fn read(&self, addr: u64, len: usize) -> Option<Vec<u8>> {
            for (base, data) in &self.blocks {
                if addr >= *base {
                    let off = (addr - *base) as usize;
                    if off < data.len() {
                        let end = off.saturating_add(len).min(data.len());
                        return Some(data[off..end].to_vec());
                    }
                }
            }
            None
        }
    }

    /// Build a MonoClassDef byte buffer with `fields_ptr` and
    /// `field_count` populated at the right offsets per
    /// `MonoOffsets::mtga_default()`.
    fn make_class_def(fields_ptr: u64, field_count: u32) -> Vec<u8> {
        let offsets = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; super::super::run::CLASS_DEF_BLOB_LEN];
        buf[offsets.class_fields..offsets.class_fields + 8]
            .copy_from_slice(&fields_ptr.to_le_bytes());
        buf[offsets.class_def_field_count..offsets.class_def_field_count + 4]
            .copy_from_slice(&field_count.to_le_bytes());
        buf
    }

    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let mut v = vec![0u8; MONO_CLASS_FIELD_SIZE];
        v[o.field_type..o.field_type + 8].copy_from_slice(&type_ptr.to_le_bytes());
        v[o.field_name..o.field_name + 8].copy_from_slice(&name_ptr.to_le_bytes());
        v[o.field_offset..o.field_offset + 4].copy_from_slice(&(offset as u32).to_le_bytes());
        v
    }

    fn make_type_block(attrs: u16) -> Vec<u8> {
        let mut v = vec![0u8; 16];
        v[8..12].copy_from_slice(&(attrs as u32).to_le_bytes());
        v
    }

    /// Populate FakeMem with a class whose `class_bytes` describe
    /// the listed `(name, offset, attrs)` instance fields.
    /// Returns the class_bytes blob.
    fn build_class(
        mem: &mut FakeMem,
        fields_array_addr: u64,
        names_base: u64,
        types_base: u64,
        fields: &[(&str, i32, u16)],
    ) -> Vec<u8> {
        let mut entry_blob = Vec::with_capacity(fields.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset, attrs)) in fields.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, *offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(*attrs));
        }
        mem.add(fields_array_addr, entry_blob);
        make_class_def(fields_array_addr, fields.len() as u32)
    }

    /// Build an object whose first 8 bytes are a vtable ptr, vtable's
    /// first 8 bytes are the class addr, and class addr resolves to
    /// `class_bytes`. Returns the object addr.
    fn install_object_with_class(
        mem: &mut FakeMem,
        object_addr: u64,
        object_payload_size: usize,
        vtable_addr: u64,
        class_addr: u64,
        class_bytes: Vec<u8>,
    ) {
        let mut payload = vec![0u8; object_payload_size.max(0x10)];
        payload[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        mem.add(object_addr, payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
        mem.add(class_addr, class_bytes);
    }

    /// In-place stamp an i32 into a payload buffer at `field_offset`.
    fn stamp_i32(payload: &mut [u8], field_offset: i32, value: i32) {
        let off = field_offset as usize;
        payload[off..off + 4].copy_from_slice(&value.to_le_bytes());
    }

    /// In-place stamp a pointer into a payload buffer at `field_offset`.
    fn stamp_ptr(payload: &mut [u8], field_offset: i32, ptr: u64) {
        let off = field_offset as usize;
        payload[off..off + 8].copy_from_slice(&ptr.to_le_bytes());
    }

    /// Build a MonoString at `addr` containing `s`.
    fn install_mono_string(mem: &mut FakeMem, addr: u64, s: &str) {
        let mut hdr = vec![0u8; 0x14];
        // length at 0x10 = number of UTF-16 code units
        let utf16: Vec<u16> = s.encode_utf16().collect();
        let len = utf16.len() as i32;
        hdr[0x10..0x14].copy_from_slice(&len.to_le_bytes());
        mem.add(addr, hdr);
        let mut chars = Vec::with_capacity(utf16.len() * 2);
        for u in &utf16 {
            chars.extend_from_slice(&u.to_le_bytes());
        }
        mem.add(addr + 0x14, chars);
    }

    #[test]
    fn read_string_field_decodes_utf16() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // Class with one field "_screenName" at offset 0x10.
        let class_bytes = build_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            &[("_screenName", 0x10, 0)],
        );

        let object_addr: u64 = 0x40_0000;
        let string_addr: u64 = 0x50_0000;
        let mut payload = vec![0u8; 0x40];
        stamp_ptr(&mut payload, 0x10, string_addr);
        mem.add(object_addr, payload);

        install_mono_string(&mut mem, string_addr, "Lagun4");

        let result = read_string_field(
            &offsets,
            &class_bytes,
            object_addr,
            "_screenName",
            &|a, l| mem.read(a, l),
        );
        assert_eq!(result, Some("Lagun4".to_string()));
    }

    #[test]
    fn read_string_field_returns_none_on_null_pointer() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let class_bytes = build_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            &[("_screenName", 0x10, 0)],
        );
        let object_addr: u64 = 0x40_0000;
        // Object payload with null at offset 0x10.
        mem.add(object_addr, vec![0u8; 0x40]);

        let result = read_string_field(
            &offsets,
            &class_bytes,
            object_addr,
            "_screenName",
            &|a, l| mem.read(a, l),
        );
        assert_eq!(result, None);
    }

    #[test]
    fn read_player_info_extracts_primitives() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let player_class_bytes = build_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            &[
                ("_screenName", 0x10, 0),
                ("SeatId", 0x68, 0),
                ("TeamId", 0x6c, 0),
                ("RankingClass", 0x74, 0),
                ("RankingTier", 0x78, 0),
                ("MythicPercentile", 0x7c, 0),
                ("MythicPlacement", 0x80, 0),
                ("CommanderGrpIds", 0x58, 0),
            ],
        );

        let object_addr: u64 = 0x40_0000;
        let string_addr: u64 = 0x50_0000;

        let mut payload = vec![0u8; 0x100];
        stamp_ptr(&mut payload, 0x10, string_addr);
        stamp_i32(&mut payload, 0x68, 1); // SeatId
        stamp_i32(&mut payload, 0x6c, 1); // TeamId
        stamp_i32(&mut payload, 0x74, 5); // RankingClass = Diamond
        stamp_i32(&mut payload, 0x78, 4); // RankingTier
        stamp_i32(&mut payload, 0x7c, 0); // MythicPercentile
        stamp_i32(&mut payload, 0x80, 0); // MythicPlacement
        stamp_ptr(&mut payload, 0x58, 0); // CommanderGrpIds null
        mem.add(object_addr, payload);

        install_mono_string(&mut mem, string_addr, "Lagun4");

        let pi = read_player_info(&offsets, &player_class_bytes, object_addr, &|a, l| {
            mem.read(a, l)
        });

        assert_eq!(pi.screen_name.as_deref(), Some("Lagun4"));
        assert_eq!(pi.seat_id, 1);
        assert_eq!(pi.team_id, 1);
        assert_eq!(pi.ranking_class, 5);
        assert_eq!(pi.ranking_tier, 4);
        assert_eq!(pi.mythic_percentile, 0);
        assert_eq!(pi.mythic_placement, 0);
        assert!(pi.commander_grp_ids.is_empty());
    }

    #[test]
    fn read_player_info_returns_zeros_for_placeholder_state() {
        // Simulates the post-tear-down state: object exists but every
        // field reads its zero value.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let player_class_bytes = build_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            &[
                ("_screenName", 0x10, 0),
                ("SeatId", 0x68, 0),
                ("TeamId", 0x6c, 0),
                ("RankingClass", 0x74, 0),
                ("RankingTier", 0x78, 0),
                ("MythicPercentile", 0x7c, 0),
                ("MythicPlacement", 0x80, 0),
                ("CommanderGrpIds", 0x58, 0),
            ],
        );

        let object_addr: u64 = 0x40_0000;
        let mut payload = vec![0u8; 0x100];
        // Stamp a placeholder string at the screen-name pointer.
        let string_addr: u64 = 0x50_0000;
        payload[0x10..0x18].copy_from_slice(&string_addr.to_le_bytes());
        mem.add(object_addr, payload);
        install_mono_string(&mut mem, string_addr, "Opponent");

        let pi = read_player_info(&offsets, &player_class_bytes, object_addr, &|a, l| {
            mem.read(a, l)
        });

        // Placeholder is detectable by the caller via the screen name
        // string itself.
        assert_eq!(pi.screen_name.as_deref(), Some("Opponent"));
        assert_eq!(pi.seat_id, 0);
        assert_eq!(pi.ranking_class, 0);
        assert_eq!(pi.ranking_tier, 0);
    }

    #[test]
    fn from_papa_singleton_returns_none_when_match_manager_null() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let papa_class_bytes = build_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            &[("MatchManager", 0x138, 0)],
        );

        let papa_singleton: u64 = 0x40_0000;
        // MatchManager pointer slot at 0x138 left zero (null).
        mem.add(papa_singleton, vec![0u8; 0x200]);

        let result = from_papa_singleton(&offsets, papa_singleton, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        });
        assert!(result.is_none(), "null MatchManager must return None");
    }

    #[test]
    fn from_papa_singleton_returns_none_when_match_manager_has_no_vtable() {
        // MatchManager pointer is non-null but the target object has
        // no readable vtable — read_object_class_def must bail and
        // the whole walk returns None.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let papa_class_bytes = build_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            &[("MatchManager", 0x138, 0)],
        );

        let papa_singleton: u64 = 0x40_0000;
        let mm_addr: u64 = 0x60_0000;
        let mut payload = vec![0u8; 0x200];
        stamp_ptr(&mut payload, 0x138, mm_addr);
        mem.add(papa_singleton, payload);
        // mm_addr has no block — read_object_class_def returns None.

        let result = from_papa_singleton(&offsets, papa_singleton, &papa_class_bytes, |a, l| {
            mem.read(a, l)
        });
        assert!(result.is_none());
    }
}
