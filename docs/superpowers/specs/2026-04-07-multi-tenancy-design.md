# Multi-Tenancy: Player-Scoped Data

## Problem

Scry2 assumes a single player. All tables lack a `player_id` column, queries return all data unfiltered, and the UI has no player context. When multiple MTGA accounts share one computer (same `Player.log`, different login sessions), all data is commingled with no way to attribute events to a specific player.

## Design

### Players Context

New bounded context `Scry2.Players` with a `players` table:

| Column | Type | Constraint |
|--------|------|------------|
| `id` | integer | PK |
| `mtga_user_id` | string | unique, not null |
| `screen_name` | string | not null |
| `first_seen_at` | utc_datetime | not null |
| `updated_at` | utc_datetime | not null |

- `mtga_user_id` is the Wizards `client_id` from `AuthenticateResponse` (e.g. `D0FECB2AF1E7FE24`)
- `screen_name` is the display name from MTGA (e.g. "Shawn McCool") — updated on each `SessionStarted`
- Auto-discovered: first `SessionStarted` with an unknown `client_id` creates a player record automatically
- Broadcasts on `players:updates`

### Event Pipeline

`IngestRawEvents` GenServer state gains `player_id` (integer FK) alongside `self_user_id` (string):

1. On `SessionStarted` → call `Players.find_or_create!(client_id, screen_name)` → store `player_id` in state
2. Every domain event struct gains a `player_id` field (required, `@enforce_keys`)
3. `domain_events` table gains an indexed `player_id` column
4. Projection handlers (`Matches.Match`, `Drafts.Draft`) pass `player_id` through

Events before the first `SessionStarted` in a log lack a player. In practice this doesn't happen — `AuthenticateResponse` is always the first meaningful event. If it does, log a warning and skip (don't persist playerless domain events).

### Domain Event Structs

All 10 event structs gain `player_id`:
- `SessionStarted`, `MatchCreated`, `MatchCompleted`, `GameCompleted`
- `DeckSubmitted`, `DieRollCompleted`, `MulliganOffered`, `RankSnapshot`
- `DraftStarted`, `DraftPickMade`

### Projection Tables

Both `matches_matches` and `drafts_drafts` gain:
- `player_id` integer column (indexed, FK to `players.id`)
- Unique constraints expand: `(player_id, mtga_match_id)` and `(player_id, mtga_draft_id)`

### Context Query API

All query functions gain an optional `player_id` parameter:
- `Matches.list_matches(player_id: nil)` — nil means all players (default)
- `Drafts.list_drafts(player_id: nil)` — same pattern
- `Matches.count/0` → `Matches.count(player_id: nil)` — same pattern
- Dashboard stats follow the same pattern

### UI: Player Selector

- Top nav dropdown, always visible (even with 1 player — makes feature discoverable)
- Options: "All Players" (default) + auto-populated from `Players.list_players()`
- Selection stored as a persistent preference in `Settings.Entry`
- All LiveViews read the active player filter and pass it to context queries
- PubSub: LiveViews subscribe to `players:updates` to refresh the dropdown when a new player is auto-discovered

### Replay Strategy

Raw MTGA events (`mtga_logs_events`) are the permanent source of truth (ADR-015) and must never be cleared during normal operation. `reset_all!` clears only domain events and projections — the layers that are rebuilt via replay from raw events.

If a bug is found in the MTGA event parser/storage layer itself, clearing raw events may be necessary, but this is an exceptional case that should prompt the user for confirmation before proceeding.

Migration path:

1. Add `player_id` columns (nullable initially)
2. Add `Players` context and table
3. Update `IngestRawEvents` to populate `player_id`
4. Update `reset_all!` to preserve raw events, only clearing domain events + projections
5. Replay from raw events → all domain events and projections rebuilt with `player_id`
6. After successful replay, tighten to NOT NULL via a follow-up migration (or leave nullable if pre-SessionStarted events are possible)

## Scope Boundaries

**In scope:**
- Players context (auto-discovery, find_or_create)
- `player_id` on all domain events and projections
- Player-filtered queries in Matches, Drafts, and Dashboard
- Player selector in top nav with persistent preference

**Out of scope:**
- Authentication / login (this is a local app, not a web service)
- Player management UI (editing names, merging players)
- Per-player settings or preferences beyond the active filter
- Multiple simultaneous Player.log watchers
