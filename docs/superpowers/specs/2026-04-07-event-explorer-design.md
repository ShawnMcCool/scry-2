# Event Explorer — Design Spec

## Context

Scry2 has 20+ domain event types flowing through an event-sourced pipeline, but no way to browse, search, or inspect them in the UI. Events are the source of truth — projections are derived — yet the only visibility is `Events.count_by_type/0` on the dashboard. As the system grows, we need a general-purpose event viewer that can also be embedded (with preset filters) in match detail, draft detail, and future pages.

This is the first implementation in a series. The componentized architecture here becomes the foundation for all future event viewing, searching, and filtering across the app.

## Architecture: Hybrid — Query API + LiveComponent Shell + Function Components

### Layer 1: Correlation Columns on `domain_events`

Three new nullable indexed columns on the `domain_events` table:

| Column | Type | Source | Purpose |
|--------|------|--------|---------|
| `match_id` | `:string` | `mtga_match_id` from event struct | Correlate match lifecycle events |
| `draft_id` | `:string` | `mtga_draft_id` from event struct | Correlate draft lifecycle events |
| `session_id` | `:string` | Propagated from `SessionStarted.session_id` via `IngestRawEvents` state | Correlate all events to their MTGA session |

**Rationale:** Domain events already carry these fields in their payloads, but querying JSON payloads requires expression indexes or full scans. Promoting them to indexed columns makes correlation queries instant. This mirrors the existing pattern where `player_id` and `event_type` are top-level columns extracted from the event for queryability.

**Population during ingestion:**
- `match_id`: extracted from the domain event struct's `mtga_match_id` field (if present) inside `Events.append!/2`
- `draft_id`: extracted from the domain event struct's `mtga_draft_id` field (if present) inside `Events.append!/2`
- `session_id`: `IngestRawEvents` adds `current_session_id` to its GenServer state (alongside existing `match_context`), set when `SessionStarted` is produced. Passed to `Events.append!/2` via a new `session_id:` option in the opts keyword list.

**Backfill:** `retranslate_from_raw!/0` re-runs translation and re-appends, so correlation columns are populated for all historical events. `session_id` backfill requires `IngestRawEvents` to replay with stateful session tracking (already the case — it processes events in order).

**Migration:** Add columns, add indexes, run retranslate to backfill.

### Layer 2: Events Query API

New function in `Scry2.Events`:

```elixir
@spec list_events(keyword()) :: {[struct()], non_neg_integer()}
def list_events(opts \\ [])
```

**Supported filters:**
- `event_types: [String.t()]` — `WHERE event_type IN (?)`
- `since: DateTime.t()` — `WHERE mtga_timestamp >= ?`
- `until: DateTime.t()` — `WHERE mtga_timestamp <= ?`
- `text_search: String.t()` — `WHERE CAST(payload AS TEXT) LIKE ?` (SQLite JSON text search)
- `match_id: String.t()` — `WHERE match_id = ?`
- `draft_id: String.t()` — `WHERE draft_id = ?`
- `session_id: String.t()` — `WHERE session_id = ?`
- `player_id: integer()` — `WHERE player_id = ?`
- `limit: integer()` — default 50
- `offset: integer()` — default 0

Returns `{rehydrated_events, total_count}` where each event is a typed domain event struct (using existing rehydration logic from `Events.get/1`).

Query is built compositionally — each filter adds a `where` clause only if present.

### Layer 3: Function Components

All in a new `Scry2Web.EventComponents` module:

**`event_filters/1`** — Renders the filter bar.
- Attrs: `filter_values` (current values), `enabled_filters` (which filters to show), `event_types` (for the type dropdown)
- Emits `phx-change="filter"` events
- Stateless — host owns filter state

**`event_list/1`** — Renders the results table + pagination.
- Attrs: `events`, `total_count`, `page`, `per_page`
- Uses `CoreComponents.table/1` slot pattern
- Each row links to `/events/:id`

**`event_row/1`** — Single event row rendering.
- Type badge (color-coded by event category: match=green, draft=blue, snapshot=amber)
- Timestamp
- Correlation indicator (match:xxxx, draft:xxxx, or session:xxxx)
- One-line summary via `EventsHelpers.event_summary/1`

**`type_badge/1`** — Event type as a colored badge.
- Color derived from event category (match lifecycle, draft lifecycle, economy, snapshot)

### Layer 4: EventExplorer LiveComponent

`Scry2Web.EventExplorer` — the composition shell.

**Assigns from host:**
- `id` (required) — DOM id
- `preset` (optional) — `%{match_id: "...", draft_id: "...", session_id: "..."}` — locked filters that the user can't change. For embedding.
- `player_id` (optional) — scoped to player

**Internal state:**
- Current filter values (merged with preset)
- Current page
- Cached results

**Behavior:**
- On mount/update: calls `Events.list_events/1` with merged filters
- On `phx-change="filter"`: updates internal filter state, re-queries
- On pagination: updates page, re-queries
- Host forwards PubSub via `send_update(EventExplorer, id: "...", refresh: true)` — component re-queries with current filters

**Embedding examples:**
```heex
<%!-- Full explorer on /events page --%>
<.live_component module={EventExplorer} id="events" player_id={@active_player_id} />

<%!-- Match detail page — locked to one match --%>
<.live_component module={EventExplorer} id="match-events" preset={%{match_id: @match.mtga_match_id}} />

<%!-- Draft detail page — locked to one draft --%>
<.live_component module={EventExplorer} id="draft-events" preset={%{draft_id: @draft.mtga_draft_id}} />
```

### Layer 5: Pages

**`/events` route — `EventsLive`**
- Thin LiveView: mounts `EventExplorer` with no preset
- Subscribes to `Topics.domain_events()`, forwards to EventExplorer via `send_update`
- URL params: filter state persisted to URL via `push_patch` for bookmarkability
- `handle_params` restores filters from URL on page load

**`/events/:id` route — `EventsLive :show`**
- Same LiveView module, detail view when `:id` param present
- Displays full event: all struct fields, raw payload JSON, correlation links, source metadata (`mtga_source_id`)
- Back-link to filtered list
- "Related events" section: links to filter by same `match_id`, `draft_id`, or `session_id`

### EventsHelpers — Pure Functions

`Scry2Web.EventsHelpers` — extracted logic per ADR-013:

- `event_summary/1` — one-line human-readable summary per event type
- `event_category/1` — classifies event into `:match`, `:draft`, `:economy`, `:session`, `:snapshot` for badge coloring
- `correlation_label/1` — returns `"match:a8f3…"` / `"draft:b71e…"` / `"session:f02c…"` or nil
- `type_badge_color/1` — returns Tailwind color class for event category

All tested with `async: true` and `build_*` factory helpers.

## What This Does NOT Include

- Streaming/real-time event tail (future: live mode that auto-appends new events)
- Event replay controls
- Raw MTGA event viewing (stays in console/debugging tools)
- Projection impact tracing ("which projections did this event update?")
- Export/download

## Verification

1. **Migration:** Run `mix ecto.migrate` — three new columns + indexes on `domain_events`
2. **Retranslate:** Run `Events.retranslate_from_raw!/0` to backfill correlation columns
3. **Query API:** In IEx, `Events.list_events(event_types: ["match_created"], limit: 5)` returns typed structs with total count
4. **Correlation search:** `Events.list_events(match_id: "some-known-id")` returns all events for that match
5. **Page:** Navigate to `/events` — filter bar renders, events load, pagination works
6. **Detail:** Click an event row — `/events/:id` shows full detail with correlation links
7. **Embedding:** On matches show page, EventExplorer renders with preset `match_id` filter
8. **Real-time:** Ingest new events — explorer refreshes after debounce
9. **Tests:** `mix test` passes — helpers tested with pure functions, query API tested against real DB
