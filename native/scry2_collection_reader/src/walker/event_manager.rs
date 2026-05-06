//! Read MTGA's active-event records from memory — the data behind
//! the dashboard's "Active events" / "4-1 in Premier Draft" surface.
//!
//! Chain (verified spike 21, MTGA build Fri Apr 11 17:22:20 2025; see
//! `mtga-duress/experiments/spikes/spike21_active_events/FINDING.md`
//! and the `mono-memory-reader` skill's Chain 3 section):
//!
//! ```text
//! PAPA._instance                                        (resolved upstream)
//!   .<EventManager>k__BackingField
//!     .<EventContexts>k__BackingField                  -> List<EventContext>
//!       [i].PlayerEvent                                 -> BasicPlayerEvent | LimitedPlayerEvent
//!             .<EventInfo>k__BackingField
//!               ._eventInfoV3                           -> EventInfoV3
//!                 .InternalEventName                    : MonoString *
//!                 .EventState                           : i32 (0=open, 1=closed, 2=special)
//!                 .FormatType                           : i32 (1=Limited, 2=Sealed, 3=Constructed)
//!             .<CourseData>k__BackingField              -> CourseData
//!               .CurrentEventState                      : i32 (0=available, 1=entered, 3=standing)
//!               .CurrentModule                          : i32
//!             .<Format>k__BackingField                  -> DeckFormat (NULL on LimitedPlayerEvent)
//!               ._formatName                            : MonoString *
//!             ._courseInfo                              -> AwsCourseInfo
//!               ._clientPlayerCourse                    -> ClientPlayerCourseV3
//!                 .CurrentWins                          : i32
//!                 .CurrentLosses                        : i32
//! ```
//!
//! Field names are looked up via [`super::field::find_field_by_name`]
//! / `_in_chain` — offsets in the FINDING/skill are diagnostic, not
//! constants. The walker survives field-position shifts between MTGA
//! builds; only renames break it.
//!
//! Tear-down behaviour: this chain is **stable across match
//! boundaries** (unlike Chain 1's `MatchManager.LocalPlayerInfo` and
//! Chain 2's `MatchSceneManager.Instance`, which evaporate post-
//! match). Pre-login, `PAPA._instance.EventManager` is null — the
//! walker returns an empty `EventList` in that case rather than
//! erroring.

use super::instance_field;
use super::limits::MAX_LIST_ELEMENTS;
use super::list_t;
use super::mono::MonoOffsets;
use super::object;

/// Cap for free-form MonoString reads (event names, format names).
/// MTGA's longest internal name in observed data is `Test_MID_Premier_Draft_7_20…`
/// — well under 128 chars.
const MAX_STRING_CHARS: usize = 128;

const PAPA_ANCHOR_FIELD: &str = "<EventManager>k__BackingField";
const EVENT_CONTEXTS_FIELD: &str = "<EventContexts>k__BackingField";

const PLAYER_EVENT_FIELD: &str = "PlayerEvent";

const EVENT_INFO_FIELD: &str = "<EventInfo>k__BackingField";
const EVENT_INFO_V3_FIELD: &str = "_eventInfoV3";
const COURSE_DATA_FIELD: &str = "<CourseData>k__BackingField";
const FORMAT_FIELD: &str = "<Format>k__BackingField";
const COURSE_INFO_FIELD: &str = "_courseInfo";
const CLIENT_PLAYER_COURSE_FIELD: &str = "_clientPlayerCourse";

const INTERNAL_EVENT_NAME_FIELD: &str = "InternalEventName";
const EVENT_STATE_FIELD: &str = "EventState";
const FORMAT_TYPE_FIELD: &str = "FormatType";
const FORMAT_NAME_FIELD: &str = "_formatName";

const CURRENT_EVENT_STATE_FIELD: &str = "CurrentEventState";
const CURRENT_MODULE_FIELD: &str = "CurrentModule";

const CURRENT_WINS_FIELD: &str = "CurrentWins";
const CURRENT_LOSSES_FIELD: &str = "CurrentLosses";

/// Snapshot of the player's full active-events list.
///
/// Returned as `Some(EventList { records: [] })` (not `None`) when
/// `PAPA._instance.EventManager` is reachable but its `EventContexts`
/// list is empty — empty list and null anchor are different states.
///
/// `None` is reserved for "chain not reachable at all" (no PAPA, no
/// EventManager pointer, etc.) — pre-login MTGA produces this.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EventList {
    pub records: Vec<EventRecord>,
}

/// Per-event projection. Every numeric field defaults to `0` when
/// the underlying field can't be resolved; string fields default to
/// `None`. The walker prefers a defaulted field over a skipped
/// record so a partial read is still useful.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EventRecord {
    /// `EventInfoV3.InternalEventName` — e.g. `"Premier_Draft_DFT"`.
    /// Not the user-facing event name; that comes from MTGA's loc
    /// tables. `internal_event_name` is the stable identifier.
    pub internal_event_name: Option<String>,

    /// `CourseData.CurrentEventState` — `0` = available, `1` =
    /// entered, `3` = standing (always-on). See FINDING for the
    /// captured distribution.
    pub current_event_state: i32,

    /// `CourseData.CurrentModule` — round/module pointer
    /// (correlated with `current_event_state`: 0/1/7/11).
    pub current_module: i32,

    /// `EventInfoV3.EventState` — event-template lifecycle:
    /// `0` = open, `1` = closed/expired, `2` = special.
    pub event_state: i32,

    /// `EventInfoV3.FormatType` — `1` = Limited, `2` = Sealed,
    /// `3` = Constructed.
    pub format_type: i32,

    /// `ClientPlayerCourseV3.CurrentWins`. Zero for "available but
    /// not yet entered" entries.
    pub current_wins: i32,

    /// `ClientPlayerCourseV3.CurrentLosses`.
    pub current_losses: i32,

    /// `DeckFormat._formatName` — e.g. `"Standard"`, `"Alchemy"`.
    /// `None` on `LimitedPlayerEvent` (Limited events resolve format
    /// from the draft pool; the `Format` slot is null at the object
    /// level).
    pub format_name: Option<String>,
}

impl EventRecord {
    /// `true` when the player is actively engaged with this event —
    /// either opted in (state 1) or in the always-available pool
    /// (state 3). Available-but-untouched entries (state 0) make up
    /// the bulk of the 50+ records and are usually filtered out at
    /// the UI surface.
    pub fn is_actively_engaged(&self) -> bool {
        self.current_event_state != 0
    }
}

/// Walk PAPA → EventManager → EventContexts → records.
///
/// Returns `None` when the EventManager anchor is null (pre-login
/// MTGA) or unreachable. Returns `Some(EventList { records: [] })`
/// when the anchor resolves but the list is empty. Per-record read
/// failures are absorbed into defaulted fields rather than dropping
/// the record, so the count of `records` always matches the live
/// `_size` of `EventContexts` (bounded by `MAX_LIST_ELEMENTS`).
pub fn from_papa_singleton<F>(
    offsets: &MonoOffsets,
    papa_singleton_addr: u64,
    papa_class_bytes: &[u8],
    read_mem: F,
) -> Option<EventList>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    // Hop 1: PAPA._instance → EventManager
    let event_manager_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        PAPA_ANCHOR_FIELD,
        &read_mem,
    )?;
    let event_manager_class = object::read_runtime_class_bytes(event_manager_addr, &read_mem)?;

    // Hop 2: EventManager.EventContexts → List<EventContext>
    let list_addr = object::read_instance_pointer(
        offsets,
        &event_manager_class,
        event_manager_addr,
        EVENT_CONTEXTS_FIELD,
        &read_mem,
    )?;
    let list_class_bytes = object::read_runtime_class_bytes(list_addr, &read_mem)?;

    // Bulk-read all element pointers at once. read_pointer_list
    // already drops nulls and bounds at MAX_LIST_ELEMENTS.
    let element_addrs = list_t::read_pointer_list(offsets, &list_class_bytes, list_addr, &read_mem);

    let mut records = Vec::with_capacity(element_addrs.len().min(MAX_LIST_ELEMENTS));
    for addr in element_addrs.into_iter().take(MAX_LIST_ELEMENTS) {
        records.push(build_event_record(offsets, addr, &read_mem));
    }

    Some(EventList { records })
}

/// Build an [`EventRecord`] for a single `EventContext` element.
///
/// Always returns a record — partial chain failures default the
/// affected fields rather than skipping. This way the position in
/// the records vec corresponds 1:1 with the live EventContexts
/// list.
fn build_event_record<F>(
    offsets: &MonoOffsets,
    event_context_addr: u64,
    read_mem: &F,
) -> EventRecord
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let mut record = EventRecord::default();

    // EventContext.PlayerEvent (polymorphic — Basic or Limited).
    let Some(event_context_class) = object::read_runtime_class_bytes(event_context_addr, read_mem)
    else {
        return record;
    };
    let Some(player_event_addr) = object::read_instance_pointer(
        offsets,
        &event_context_class,
        event_context_addr,
        PLAYER_EVENT_FIELD,
        read_mem,
    ) else {
        return record;
    };
    let Some(player_event_class) = object::read_runtime_class_bytes(player_event_addr, read_mem)
    else {
        return record;
    };

    fill_event_info(
        offsets,
        player_event_addr,
        &player_event_class,
        &mut record,
        read_mem,
    );
    fill_course_data(
        offsets,
        player_event_addr,
        &player_event_class,
        &mut record,
        read_mem,
    );
    fill_format(
        offsets,
        player_event_addr,
        &player_event_class,
        &mut record,
        read_mem,
    );
    fill_wins_losses(
        offsets,
        player_event_addr,
        &player_event_class,
        &mut record,
        read_mem,
    );

    record
}

/// `PlayerEvent.<EventInfo>k__BackingField → BasicEventInfo._eventInfoV3 → EventInfoV3`
/// → InternalEventName, EventState, FormatType.
///
/// `<EventInfo>` is declared on `BasicPlayerEvent`, so a
/// `LimitedPlayerEvent` inherits it — must use the parent-chain
/// resolver.
fn fill_event_info<F>(
    offsets: &MonoOffsets,
    player_event_addr: u64,
    player_event_class: &[u8],
    record: &mut EventRecord,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(event_info_addr) = object::read_instance_pointer_in_chain(
        offsets,
        player_event_class,
        player_event_addr,
        EVENT_INFO_FIELD,
        read_mem,
    ) else {
        return;
    };
    let Some(event_info_class) = object::read_runtime_class_bytes(event_info_addr, read_mem)
    else {
        return;
    };

    let Some(v3_addr) = object::read_instance_pointer_in_chain(
        offsets,
        &event_info_class,
        event_info_addr,
        EVENT_INFO_V3_FIELD,
        read_mem,
    ) else {
        return;
    };
    let Some(v3_class) = object::read_runtime_class_bytes(v3_addr, read_mem) else {
        return;
    };

    record.internal_event_name = instance_field::read_instance_string(
        offsets,
        &v3_class,
        v3_addr,
        INTERNAL_EVENT_NAME_FIELD,
        MAX_STRING_CHARS,
        read_mem,
    );
    record.event_state = instance_field::read_instance_i32(
        offsets,
        &v3_class,
        v3_addr,
        EVENT_STATE_FIELD,
        read_mem,
    )
    .unwrap_or(0);
    record.format_type = instance_field::read_instance_i32(
        offsets,
        &v3_class,
        v3_addr,
        FORMAT_TYPE_FIELD,
        read_mem,
    )
    .unwrap_or(0);
}

/// `PlayerEvent.<CourseData> → CourseData → CurrentEventState, CurrentModule`.
fn fill_course_data<F>(
    offsets: &MonoOffsets,
    player_event_addr: u64,
    player_event_class: &[u8],
    record: &mut EventRecord,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(course_data_addr) = object::read_instance_pointer_in_chain(
        offsets,
        player_event_class,
        player_event_addr,
        COURSE_DATA_FIELD,
        read_mem,
    ) else {
        return;
    };
    let Some(course_data_class) = object::read_runtime_class_bytes(course_data_addr, read_mem)
    else {
        return;
    };

    record.current_event_state = instance_field::read_instance_i32(
        offsets,
        &course_data_class,
        course_data_addr,
        CURRENT_EVENT_STATE_FIELD,
        read_mem,
    )
    .unwrap_or(0);
    record.current_module = instance_field::read_instance_i32(
        offsets,
        &course_data_class,
        course_data_addr,
        CURRENT_MODULE_FIELD,
        read_mem,
    )
    .unwrap_or(0);
}

/// `PlayerEvent.<Format> → DeckFormat._formatName`. Null is normal
/// on `LimitedPlayerEvent` (limited derives format from the draft
/// pool); leave the record's `format_name` as `None` in that case.
fn fill_format<F>(
    offsets: &MonoOffsets,
    player_event_addr: u64,
    player_event_class: &[u8],
    record: &mut EventRecord,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(format_addr) = object::read_instance_pointer_in_chain(
        offsets,
        player_event_class,
        player_event_addr,
        FORMAT_FIELD,
        read_mem,
    ) else {
        return;
    };
    let Some(format_class) = object::read_runtime_class_bytes(format_addr, read_mem) else {
        return;
    };

    record.format_name = instance_field::read_instance_string(
        offsets,
        &format_class,
        format_addr,
        FORMAT_NAME_FIELD,
        MAX_STRING_CHARS,
        read_mem,
    );
}

/// `PlayerEvent._courseInfo → AwsCourseInfo._clientPlayerCourse → ClientPlayerCourseV3`
/// → CurrentWins, CurrentLosses.
fn fill_wins_losses<F>(
    offsets: &MonoOffsets,
    player_event_addr: u64,
    player_event_class: &[u8],
    record: &mut EventRecord,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(course_info_addr) = object::read_instance_pointer_in_chain(
        offsets,
        player_event_class,
        player_event_addr,
        COURSE_INFO_FIELD,
        read_mem,
    ) else {
        return;
    };
    let Some(course_info_class) = object::read_runtime_class_bytes(course_info_addr, read_mem)
    else {
        return;
    };

    let Some(cpc_addr) = object::read_instance_pointer(
        offsets,
        &course_info_class,
        course_info_addr,
        CLIENT_PLAYER_COURSE_FIELD,
        read_mem,
    ) else {
        return;
    };
    let Some(cpc_class) = object::read_runtime_class_bytes(cpc_addr, read_mem) else {
        return;
    };

    record.current_wins = instance_field::read_instance_i32(
        offsets,
        &cpc_class,
        cpc_addr,
        CURRENT_WINS_FIELD,
        read_mem,
    )
    .unwrap_or(0);
    record.current_losses = instance_field::read_instance_i32(
        offsets,
        &cpc_class,
        cpc_addr,
        CURRENT_LOSSES_FIELD,
        read_mem,
    )
    .unwrap_or(0);
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_record_actively_engaged_flag() {
        // state 0 (Available) — not engaged.
        let mut r = EventRecord::default();
        assert!(!r.is_actively_engaged());

        // state 1 (Entered) — engaged.
        r.current_event_state = 1;
        assert!(r.is_actively_engaged());

        // state 3 (Standing — Play, Ladder) — engaged.
        r.current_event_state = 3;
        assert!(r.is_actively_engaged());

        // unexpected non-zero state — still treated as engaged. The
        // FINDING captured 0/1/3 only, but the rule "non-zero means
        // engaged" is the safe default.
        r.current_event_state = 99;
        assert!(r.is_actively_engaged());
    }

    #[test]
    fn event_record_default_values() {
        let r = EventRecord::default();
        assert_eq!(r.internal_event_name, None);
        assert_eq!(r.current_event_state, 0);
        assert_eq!(r.current_module, 0);
        assert_eq!(r.event_state, 0);
        assert_eq!(r.format_type, 0);
        assert_eq!(r.current_wins, 0);
        assert_eq!(r.current_losses, 0);
        assert_eq!(r.format_name, None);
    }

    #[test]
    fn event_list_default_is_empty() {
        let list = EventList::default();
        assert!(list.records.is_empty());
    }

    /// `from_papa_singleton` returns `None` when PAPA's
    /// `<EventManager>k__BackingField` resolves to a null pointer
    /// (pre-login MTGA, or a freshly torn-down session).
    #[test]
    fn from_papa_returns_none_when_event_manager_anchor_null() {
        // No memory installed → every pointer read returns None →
        // `read_instance_pointer` returns None on the first hop.
        let offsets = MonoOffsets::mtga_default();
        let read = |_addr: u64, _len: usize| -> Option<Vec<u8>> { None };
        let result = from_papa_singleton(&offsets, 0x1000, &[0u8; 256], read);
        assert!(result.is_none());
    }
}
