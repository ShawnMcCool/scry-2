# Memory Observation Enrichment for Match Records

**Status:** Approved (2026-05-03)
**Scope:** Chain 1 only (gap-filler fields). Chain 2 (board state / opponent revealed cards) is explicitly out of scope and will land in a separate work stream.

---

## Problem

`Scry2.LiveState.Server` polls MTGA's process memory every 500 ms during a match and broadcasts the resulting snapshots to a transient HUD (`Scry2Web.Components.LiveMatchCard`). At match wind-down it persists one final snapshot to `live_state_snapshots`.

The persistent `matches_matches` and `decks_match_results` rows already declare `opponent_screen_name`, `opponent_rank`, and `player_rank` columns — but those are only populated by `MatchProjection` / `DeckProjection` from the **log** translation path, where opponent rank is essentially always nil and opponent screen name is often anonymized.

The result: the rich memory observation lives in a side-table (`live_state_snapshots`) and on a transient HUD, but never reaches the historical match record. Every downstream consumer (match history, deck-with-opponent stats, opponent profiles) reads the impoverished log-derived fields.

## Goal

Land memory-derived gap-filler fields onto the persistent match record via a structurally clean pattern that mirrors the existing memory-observation precedents in this codebase (`Economy.IngestMemoryGrants`, `Crafts.IngestCollectionDiffs`) and accommodates Chain 2 (opponent revealed cards) as future work without changes.

## Scope

**In scope (gap-filler fields the log can never reliably deliver):**

- `opponent_screen_name`
- `opponent_rank` (composed from `opponent_ranking_class` + `opponent_ranking_tier`)
- `opponent_rank_mythic_percentile` (new column)
- `opponent_rank_mythic_placement` (new column)
- `player_rank` (composed from `local_ranking_class` + `local_ranking_tier`)

**Out of scope (deliberate):**

- Opponent commander identification (`commander_grp_ids`) — Brawl/Commander rendering deferred until real-world data accumulates.
- Backfill of historical matches from existing `live_state_snapshots` rows (~3 days of data, YAGNI v1).
- Chain 2 board state / opponent revealed cards (gated on walker `card_holder.rs`; separate work).
- Memory-vs-log reconciliation of overlapping fields (separate quality feature).

## Architecture

```
LiveState.Server
  └─ broadcasts {:final, %Snapshot{}} on live_match:final  [existing]
        ├─ Matches.MergeOpponentObservation                [new]
        │     └─ updates matches_matches row by mtga_match_id
        │     └─ broadcasts on matches:updates
        └─ Decks.MergeMatchResultObservation               [new]
              └─ updates decks_match_results row by mtga_match_id
              └─ broadcasts on decks:updates
```

**Key properties:**

- **No new event source.** `live_match:final` already exists; `LiveState.Server` already owns it. Single-publisher-per-topic rule preserved.
- **Each context owns its own enricher.** Matches enriches `matches_matches`. Decks enriches `decks_match_results`. No cross-context calls.
- **Memory-wins-when-present.** The merge drops nil fields from the snapshot before update, so partial walker output (e.g., screen_name resolved but rank not) never wipes log-derived values that did make it through.
- **Forward-only enrichment.** Matches that completed before this lands stay log-only.
- **Approach 1 over Approach 2:** A dedicated subscriber per context keeps `MatchProjection` purely event-sourced (single responsibility: translate domain events → matches rows). The enricher's responsibility (merge memory observation → matches row) is conceptually distinct and follows the established memory-observation precedent.
- **Forward compatibility with Chain 2:** Board-state walking will produce a *continuous* poll output (not single-snapshot) persisted to a new table (e.g., `match_opponent_reveals`) by a new dedicated subscriber. Doesn't touch this design.

## Schema changes

Two migrations, identical column additions:

```elixir
# priv/repo/migrations/<timestamp>_add_opponent_mythic_to_matches.exs
alter table(:matches_matches) do
  add :opponent_rank_mythic_percentile, :integer
  add :opponent_rank_mythic_placement, :integer
end

# priv/repo/migrations/<timestamp>_add_opponent_mythic_to_decks_match_results.exs
alter table(:decks_match_results) do
  add :opponent_rank_mythic_percentile, :integer
  add :opponent_rank_mythic_placement, :integer
end
```

Schema modules `Scry2.Matches.Match` and `Scry2.Decks.MatchResult` declare the new fields and include them in their `cast/3` lists.

**Type note:** `opponent_rank_mythic_percentile` typed `:integer` per the walker's current emission. Memory.md flags this as "i32 (probable)" pending live verification with a Mythic-tier player. Migration to a decimal type later is a small follow-up if discovery proves it's `f32`.

## Topics consistency fix

`Scry2.LiveState` currently defines its PubSub topics locally (`@updates_topic "live_match:updates"`, `@final_topic "live_match:final"`). The project rule (CLAUDE.md, `Topics` module @moduledoc) is that all topic strings live in `Scry2.Topics` so cross-context subscribers can use a central registry.

Add to `Scry2.Topics`:

```elixir
@doc "In-flight memory observations during an active match."
def live_match_updates, do: "live_match:updates"

@doc "Final memory observation persisted at match wind-down."
def live_match_final, do: "live_match:final"
```

Update `Scry2.LiveState`:
- `updates_topic/0` and `final_topic/0` delegate to `Topics.live_match_updates/0` and `Topics.live_match_final/0` respectively.
- Internal `@updates_topic` / `@final_topic` constants removed.

This is a small consistency fix bundled with the work — the new subscriber modules need a registry entry to follow the rule cleanly.

## New modules

### `Scry2.Matches.MergeOpponentObservation`

GenServer in the Matches context.

```elixir
defmodule Scry2.Matches.MergeOpponentObservation do
  use GenServer

  alias Scry2.LiveState.Snapshot
  alias Scry2.{Matches, Topics}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.live_match_final())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:final, %Snapshot{} = snap}, state) do
    Matches.merge_opponent_observation(snap)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}
end
```

### `Scry2.Matches.merge_opponent_observation/1`

Public function in `Scry2.Matches` facade. Pure logic + DB update.

```elixir
def merge_opponent_observation(%LiveState.Snapshot{} = snap) do
  attrs = enrichment_attrs(snap)

  cond do
    map_size(attrs) == 0 ->
      :ok

    true ->
      case Repo.get_by(Match, mtga_match_id: snap.mtga_match_id) do
        nil ->
          Log.warning(:ingester, fn ->
            "merge_opponent_observation: no match for mtga_match_id=#{snap.mtga_match_id}"
          end)
          :ok

        %Match{} = match ->
          {:ok, updated} =
            match
            |> Match.changeset(attrs)
            |> Repo.update()

          Topics.broadcast(Topics.matches_updates(), {:match_updated, updated})
          {:ok, updated}
      end
  end
end

defp enrichment_attrs(%Snapshot{} = snap) do
  %{
    opponent_screen_name: snap.opponent_screen_name,
    opponent_rank: RankFormat.compose(snap.opponent_ranking_class, snap.opponent_ranking_tier),
    opponent_rank_mythic_percentile: snap.opponent_mythic_percentile,
    opponent_rank_mythic_placement: snap.opponent_mythic_placement,
    player_rank: RankFormat.compose(snap.local_ranking_class, snap.local_ranking_tier)
  }
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  |> Map.new()
end
```

### `Scry2.Decks.MergeMatchResultObservation` + `Scry2.Decks.merge_match_result_observation/1`

Mirror pair for `decks_match_results`. Same shape, looks up by `mtga_match_id`, broadcasts on `decks:updates`.

### `Scry2.Matches.RankFormat`

Tiny helper module. Three lines, three callers (extracted from existing `MatchProjection.compose_rank/2` duplication, reused by both new merge functions and the future `RankBadge` component):

```elixir
defmodule Scry2.Matches.RankFormat do
  @moduledoc "Compose human-readable rank strings from MTGA's class+tier pair."

  @spec compose(String.t() | nil, integer() | nil) :: String.t() | nil
  def compose(nil, _tier), do: nil
  def compose(class, nil), do: class
  def compose(class, tier), do: "#{class} #{tier}"
end
```

`MatchProjection.compose_rank/2` and `DeckProjection.compose_rank/2` updated to delegate to `RankFormat.compose/2` (eliminate duplication).

### Supervisor wiring

Both new GenServers added to the `Scry2.Application` supervision tree, after `LiveState.Server` (so subscribers exist before the publisher could fire), with `restart: :transient`.

## Consumer feature: match detail page enrichment

Render in the match detail LiveView (location to be confirmed during implementation):

- **Opponent screen name** — `match.opponent_screen_name || "Opponent"`.
- **Opponent rank** — composed string with Mythic-tier suffix:
  - When `opponent_rank_mythic_placement` is present (top-of-ladder): `"Mythic #142"`
  - Else when `opponent_rank_mythic_percentile` is present: `"Mythic 88%"`
  - Else: bare rank string (e.g. `"Gold 3"`, `"Mythic"`)
- **Player rank** — same composition logic.

New small component `Scry2Web.Components.RankBadge` for consistent styling. Reusable in the live HUD card later. Receives the rank string + optional mythic placement/percentile and renders the appropriate display.

## Error handling

| Case | Behavior |
|---|---|
| Match row not found by `mtga_match_id` | `:ingester` warning, return `:ok`. Possible if log ingestion lags far behind, though in practice MatchCompleted is processed before wind-down. |
| Snapshot has only nil enrichable fields (walker degraded; `reader_version: "unknown"`) | No-op, no broadcast. |
| Changeset error on update | `:ingester` error log, return `{:error, changeset}`. Don't crash GenServer. |
| Subscriber GenServer crash | `:transient` supervisor restart. Observation already persisted in `live_state_snapshots`; only the merge attempt for one snapshot is lost. |
| Race: snapshot arrives before MatchCreated projected | Match-not-found warning. Mitigation deferred (YAGNI v1) — `live_state_snapshots` row is preserved; future enhancement can re-attempt merge when a new match row appears. |

## Testing

### `Scry2.Matches.merge_opponent_observation/1` (`DataCase`)

- Snapshot with all gap-filler fields populated → match row updated, all fields written, broadcast sent
- Snapshot with partial fields (screen_name only) → only screen_name updated; existing log-derived values preserved
- Snapshot with all-nil enrichable fields → no-op, no broadcast
- Snapshot for non-existent match → `:ingester` warning, no crash

### `Scry2.Matches.MergeOpponentObservation` GenServer (`DataCase`)

- Send `{:final, %Snapshot{}}` directly to the GenServer; verify match row updated and broadcast received.
- Other PubSub messages ignored.
- No `:sys` introspection (per ADR-009).

### `Scry2.Decks.merge_match_result_observation/1` + `Scry2.Decks.MergeMatchResultObservation` (`DataCase`)

- Same shape as the Matches pair.

### `Scry2.Matches.RankFormat`

- Unit tests for the three branches (nil class, nil tier, both present).

### Match detail LiveView (`ConnCase` integration)

- Mount with match having memory-enriched fields → rendered values match.
- Mount with match having only log-derived (or missing) fields → graceful fallback rendering.
- Mount with Mythic placement / Mythic percentile / sub-Mythic rank → each renders correctly.

### `Scry2Web.Components.RankBadge`

- Pure component test: each rank-tier display variant renders the expected text.

## Migration order

1. Schema migrations (matches_matches, decks_match_results).
2. `Scry2.Matches.RankFormat` module.
3. `Scry2.Topics` additions + `Scry2.LiveState` delegation.
4. `Scry2.Matches.merge_opponent_observation/1` + `Scry2.Matches.MergeOpponentObservation`.
5. `Scry2.Decks.merge_match_result_observation/1` + `Scry2.Decks.MergeMatchResultObservation`.
6. Supervisor wiring for both new GenServers.
7. `MatchProjection.compose_rank/2` and `DeckProjection.compose_rank/2` delegate to `RankFormat.compose/2`.
8. `Scry2Web.Components.RankBadge` component.
9. Match detail LiveView enrichment.

## Verification

- `mix precommit` clean (zero warnings, zero failing tests).
- Manual verification: trigger a memory snapshot via tidewave eval, observe `live_match:final` broadcast, observe `matches:updates` broadcast, query DB to confirm enrichment landed.
- Tidewave logs check: no errors during snapshot → merge → broadcast cycle.

## Out of scope (deliberate)

- Brawl/Commander rendering and `commander_grp_ids` schema column.
- Backfill of historical matches.
- Chain 2 board state / opponent revealed cards.
- Memory-vs-log reconciliation of overlapping fields.
- Rendering local rank trajectory (Ranks context already owns that).
