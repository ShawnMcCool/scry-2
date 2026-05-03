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
//! Field names are resolved dynamically via [`super::field::find_field_by_name`]
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

use super::instance_field;
use super::mono::MonoOffsets;
use super::object;

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
    let mm_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        PAPA_MATCH_MANAGER_FIELD,
        &read_mem,
    )?;

    let mm_class_bytes = object::read_runtime_class_bytes(mm_addr, &read_mem)?;

    let mut values = MatchInfoValues::default();

    if let Some(local_addr) = object::read_instance_pointer(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "LocalPlayerInfo",
        &read_mem,
    ) {
        if let Some(class_bytes) = object::read_runtime_class_bytes(local_addr, &read_mem) {
            values.local = read_player_info(offsets, &class_bytes, local_addr, &read_mem);
        }
    }

    if let Some(opp_addr) =
        object::read_instance_pointer(offsets, &mm_class_bytes, mm_addr, "OpponentInfo", &read_mem)
    {
        if let Some(class_bytes) = object::read_runtime_class_bytes(opp_addr, &read_mem) {
            values.opponent = read_player_info(offsets, &class_bytes, opp_addr, &read_mem);
        }
    }

    values.match_id = instance_field::read_instance_string(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "MatchID",
        MAX_STRING_CHARS,
        &read_mem,
    );
    values.format = read_i32_or_zero(offsets, &mm_class_bytes, mm_addr, "Format", &read_mem);
    values.variant = read_i32_or_zero(offsets, &mm_class_bytes, mm_addr, "Variant", &read_mem);
    values.session_type =
        read_i32_or_zero(offsets, &mm_class_bytes, mm_addr, "SessionType", &read_mem);
    values.current_game_number = read_i32_or_zero(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "CurrentGameNumber",
        &read_mem,
    );
    values.match_state =
        read_i32_or_zero(offsets, &mm_class_bytes, mm_addr, "MatchState", &read_mem);
    values.local_player_seat_id = read_i32_or_zero(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "LocalPlayerSeatId",
        &read_mem,
    );
    values.is_practice_game = read_bool_or_false(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "IsPracticeGame",
        &read_mem,
    );
    values.is_private_game = read_bool_or_false(
        offsets,
        &mm_class_bytes,
        mm_addr,
        "IsPrivateGame",
        &read_mem,
    );

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
        screen_name: instance_field::read_instance_string(
            offsets,
            class_bytes,
            object_addr,
            "_screenName",
            MAX_STRING_CHARS,
            read_mem,
        ),
        seat_id: read_i32_or_zero(offsets, class_bytes, object_addr, "SeatId", read_mem),
        team_id: read_i32_or_zero(offsets, class_bytes, object_addr, "TeamId", read_mem),
        ranking_class: read_i32_or_zero(
            offsets,
            class_bytes,
            object_addr,
            "RankingClass",
            read_mem,
        ),
        ranking_tier: read_i32_or_zero(offsets, class_bytes, object_addr, "RankingTier", read_mem),
        mythic_percentile: read_i32_or_zero(
            offsets,
            class_bytes,
            object_addr,
            "MythicPercentile",
            read_mem,
        ),
        mythic_placement: read_i32_or_zero(
            offsets,
            class_bytes,
            object_addr,
            "MythicPlacement",
            read_mem,
        ),
        commander_grp_ids: instance_field::read_instance_int_list(
            offsets,
            class_bytes,
            object_addr,
            "CommanderGrpIds",
            MAX_COMMANDER_LIST,
            read_mem,
        )
        .unwrap_or_default(),
    }
}

use super::limits::{MAX_COMMANDER_LIST, MAX_STRING_CHARS};

// ─── coalescing wrappers ────────────────────────────────────────────
//
// `MatchInfoValues` and `PlayerInfoValues` use silent-zero / silent-
// false defaults (audit finding 1.3 will revisit this in a follow-up).
// These two wrappers exist only to coalesce `instance_field`'s
// `Option<_>` returns into the concrete defaults the structs hold.

fn read_i32_or_zero<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> i32
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    instance_field::read_instance_i32(offsets, class_bytes, object_addr, field_name, read_mem)
        .unwrap_or(0)
}

fn read_bool_or_false<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> bool
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    instance_field::read_instance_bool(offsets, class_bytes, object_addr, field_name, read_mem)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_type_block, FakeMem};

    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        crate::walker::test_support::make_field_entry(name_ptr, type_ptr, 0, offset)
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

        let result = instance_field::read_instance_string(
            &offsets,
            &class_bytes,
            object_addr,
            "_screenName",
            MAX_STRING_CHARS,
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

        let result = instance_field::read_instance_string(
            &offsets,
            &class_bytes,
            object_addr,
            "_screenName",
            MAX_STRING_CHARS,
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
