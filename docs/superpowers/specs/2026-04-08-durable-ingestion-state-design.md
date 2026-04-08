# Durable Ingestion State

## Problem

The translation state in `IngestRawEvents` is entirely in-memory. On restart, it starts blank. If the app crashes mid-match, resume produces domain events with nil match IDs, nil ranks, and missing deck data. The only recovery is a full reingest — replaying all ~6,500+ raw events from the beginning.

The state has grown organically (12+ fields across session and match scopes), updated in multiple scattered functions. There's no explicit contract, no persistence, and no way to resume from a checkpoint.

## Design

### IngestionState struct

A typed struct representing the full translation context, versioned and serializable.

```
Scry2.Events.IngestionState
├── version: integer (for forward migration)
├── last_raw_event_id: integer (cursor into raw event stream)
├── session: %Session{}
│   ├── self_user_id
│   ├── player_id
│   ├── current_session_id
│   ├── constructed_rank
│   └── limited_rank
└── match: %Match{}
    ├── current_match_id
    ├── current_game_number
    ├── last_deck_name
    ├── on_play_for_current_game
    ├── pending_deck
    └── last_hand_game_objects
```

Session state survives match boundaries. Match state is reset to a fresh `%Match{}` on MatchCompleted. If other scope levels emerge, they become explicit sub-structs.

Fixed schema — when shape changes, bump version and add defaults for new fields.

### State transitions via apply_event

Pure function: given current state + domain event, return `{new_state, side_effects}`.

```elixir
IngestionState.apply_event(state, %MatchCreated{}) -> {new_state, []}
IngestionState.apply_event(state, %MatchCreated{}) -> {new_state, [%DeckSubmitted{}]}  # pending deck
IngestionState.apply_event(state, %MatchCompleted{}) -> {reset_match_state, []}
```

Side effects are domain events that were deferred (e.g., DeckSubmitted from a ConnectResp that arrived before MatchCreated). The caller appends them to the event list for persistence.

Every `apply_event` clause operates on typed domain event structs, never raw JSON. Raw payload extraction (`cache_game_objects`, `capture_rank`) stays in `IngestRawEvents` as impure helpers — they decode JSON from `EventRecord` payloads and feed clean data into the state.

Key property: `apply_event` is deterministic. Same state + same event = same output. This is what makes replay reliable.

### Persistence

Single table `ingestion_state`, one row (singleton).

| Column | Type | Purpose |
|---|---|---|
| id | integer | Always 1 |
| version | integer | Struct version for migration |
| last_raw_event_id | integer | Cursor into raw event stream |
| session | json | Serialized `%Session{}` |
| match | json | Serialized `%Match{}` |
| updated_at | utc_datetime | Last write time |

Written after each raw event is fully processed (`mark_processed!` then snapshot write). If crash between the two, catch-up at init reprocesses that one event — idempotent by design.

Serialization: `Jason.encode!/1` on structs. Deserialization via `from_json/1` with version migration (fill defaults for missing fields from older snapshots).

Note: `pending_deck` stores a `%DeckSubmitted{}` struct. On serialization this becomes a plain map. On deserialization, `from_json/1` must reconstruct the struct from the map (or store it as a plain map and reconstruct on emit). `last_hand_game_objects` is already a plain map and serializes naturally.

### Startup and resume

On `IngestRawEvents.init/1`:

1. Load snapshot from `ingestion_state` table
2. If found: deserialize, migrate version if needed, set as GenServer state
3. If missing: fresh `%IngestionState{}` with `last_raw_event_id: 0`
4. Proactive catch-up: query `mtga_logs_events WHERE id > last_raw_event_id AND processed = false ORDER BY id` and process each
5. Subscribe to PubSub for new events

The catch-up query closes the gap for raw events persisted but not yet translated (e.g., crash after watcher wrote the event but before IngestRawEvents processed the PubSub message).

### Fallback

If snapshot is corrupt or deleted: fresh `%IngestionState{}` + `last_raw_event_id: 0`. The existing reingest path handles this — all raw events replay from the beginning through the translator with correct state accumulation.

### IngestRawEvents becomes thin wiring

The GenServer delegates to `IngestionState` for all state logic:

1. `cache_game_objects` / `capture_rank` — raw payload extraction (stays in IngestRawEvents)
2. `IdentifyDomainEvents.translate/3` — pure translation
3. `IngestionState.apply_event/2` — pure state transition, may produce side-effect events
4. `IngestionState.advance/2` — bump `last_raw_event_id`
5. Persist snapshot to DB

## What doesn't change

- `IdentifyDomainEvents` — still pure, still stateless
- Projectors — still subscribe to domain events, unaware of ingestion state
- Watcher and byte cursor — unchanged
- Enrichment module — still called by IngestRawEvents, receives state
- PubSub topology — unchanged

## Files

- New: `lib/scry_2/events/ingestion_state.ex`
- New: `lib/scry_2/events/ingestion_state/session.ex`
- New: `lib/scry_2/events/ingestion_state/match.ex`
- New: migration for `ingestion_state` table
- Modified: `lib/scry_2/events/ingest_raw_events.ex`
- New: tests for IngestionState pure functions

## Verification

1. `mix test` — all existing tests pass (IngestRawEvents tests exercise the same logic through new struct)
2. New unit tests: `IngestionState.apply_event/2` for each domain event type, including pending_deck emission
3. New test: serialize → deserialize round-trip with version migration
4. New test: startup with existing snapshot resumes correctly
5. New test: startup with no snapshot falls back to fresh state
6. Manual: restart dev server mid-match, verify match context survives
7. Manual: reingest, verify all matches have correct deck_colors
