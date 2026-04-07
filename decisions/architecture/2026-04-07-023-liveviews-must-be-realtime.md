---
status: accepted
date: 2026-04-07
---
# All LiveViews must update in real time via PubSub

## Context and Problem Statement

Scry2 is a real-time-first LiveView application. Every page should reflect the current state of the system without requiring a manual reload. ADR-011 (mutation broadcast contract) established the broadcasting side — every mutation publishes to PubSub. This ADR establishes the receiving side.

Three problems prompted this decision:

1. **Player filter silently dropped.** `MatchesLive.handle_info({:match_updated, _}, socket)` calls `Matches.list_matches(limit: 100)` without passing the current `active_player_id`. After a PubSub update, the view reverts to showing all-player data until the next `handle_params`. `DraftsLive` has the same bug.
2. **No debounce on PubSub handlers.** During bulk log ingestion (hundreds of events in seconds), each `:match_updated` message triggers a separate database query. N events = N queries, most of which are immediately superseded.
3. **Inconsistent pattern.** Each LiveView handles PubSub updates slightly differently — some re-fetch, some update counts inline — making it easy to introduce new filter-dropping or query-storm bugs.

## Decision Outcome

Chosen option: "Every LiveView must subscribe, debounce, and re-fetch with current filters."

The pattern has three rules:

1. **Subscribe in mount** inside the `connected?(socket)` gate, using `Topics.subscribe/1`. This is already done in all LiveViews.
2. **Debounce rapid updates** using cancel-and-reschedule: on receiving a PubSub message, cancel any pending `:reload_data` timer and schedule a new one at 500ms. This collapses N rapid events into one database query after a quiet period.
3. **Re-fetch with current assigns.** The reload handler must pass the current `active_player_id` (and any other active filters like `filters` in CardsLive) when fetching data. Never call a bare `list_*` without the current filter state.

Implementation pattern (via `Scry2Web.LiveHelpers.schedule_reload/2`):

```elixir
@impl true
def handle_info({:match_updated, _}, socket) do
  {:noreply, schedule_reload(socket)}
end

@impl true
def handle_info(:reload_data, socket) do
  player_id = socket.assigns[:active_player_id]
  matches = Matches.list_matches(limit: 100, player_id: player_id)
  {:noreply, assign(socket, matches: matches, reload_timer: nil)}
end
```

### Consequences

* Good, because users see updates immediately without manual refresh
* Good, because player filter is never silently dropped on PubSub update
* Good, because debouncing prevents query storms during bulk ingestion
* Good, because the pattern is consistent across all LiveViews — no special cases
* Neutral, because 500ms latency between mutation and UI update is acceptable for an analytics dashboard
* Neutral, because each new data-producing code path must broadcast — but this is already the established convention (ADR-011)
