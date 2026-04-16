# vs Opponent Panel — Component Design

**Date:** 2026-04-16  
**Status:** Approved

## Context

The match detail view already shows an inline "vs opponent" section (`opponent_history/1` in `matches_live.ex`), but it is a private `defp` that can't be reused. The same summary — record, history list — is useful in other contexts (deck detail, draft detail, future opponent-focused views). The current implementation is also thin: it shows only a text record string and a match list, with no stats row and no chart. This design extracts and enriches it into a reusable, properly bounded component.

## What Gets Built

A public component `<.opponent_panel>` that shows:

1. **Header** — "vs [opponent]" in `font-beleren`, with the opponent's most-recent rank icon beside the name (if present in the history)
2. **Stats row** — two `<.stat_card>` tiles: **Record** ("W–L") and **Win Rate** ("%")
3. **Winrate chart** — cumulative win rate over sequential matches, using the existing `phx-hook="Chart"` / `data-chart-type="cumulative_winrate"` pattern; only rendered when `length(history) >= 3`
4. **Match history list** — same row pattern as current: result letter + set icon + format label + datetime, each linking to that match

Empty state (first time facing this opponent): a single muted line, no stats, no chart, no list.

## Component Interface

```heex
<.opponent_panel
  id="match-opponent"
  opponent={@match.opponent_screen_name}
  history={@opponent_history}
/>
```

Attributes:
- `id` — required string, used to disambiguate the chart DOM element when multiple panels exist on a page
- `opponent` — required string, the opponent screen name
- `history` — required list of `%Match{}` structs (all previous matches, chronologically ascending for chart computation, rendered descending for display — component sorts internally)

## Files

### New: `lib/scry_2_web/components/opponent_components.ex`

Defines `<.opponent_panel>`. All template logic stays in the component; all data transformations delegated to helpers. Uses `<.stat_card>` from `core_components.ex`, `<.rank_icon>`, `<.set_icon>` from existing components.

### New: `lib/scry_2_web/live/opponent_helpers.ex`

Pure helper module (per ADR-013). No DB, no side effects.

Functions:
- `record(history)` → `{wins, losses}` — counts `won == true` and `won == false`
- `win_rate(wins, losses)` → `float | nil` — nil when total is 0
- `format_win_rate(win_rate)` → `"67%"` string (nil → `"—"`)
- `chart_series(history)` → JSON string compatible with `cumulative_winrate` chart type — takes history sorted ascending by `started_at`, emits same series format as `MatchesHelpers.cumulative_winrate_series/1`
- `latest_rank(history)` → rank string from the most recent match in the history, or nil

### Modified: `lib/scry_2_web/live/matches_live.ex`

- Remove private `opponent_history/1`
- Add `import Scry2Web.OpponentComponents` (or alias via `use Scry2Web, :live_view` if components are wired in)
- Replace `<.opponent_history ...>` call site with `<.opponent_panel id="match-opponent" ...>`
- `assign_detail/2` already calls `Matches.opponent_matches/2` — no change needed there

### No change needed to chart infrastructure

`LiveHelpers.cumulative_winrate_series/1` (in `lib/scry_2_web/live/live_helpers.ex`) already exists and accepts `[%{timestamp, win_rate, wins, total}]`. `OpponentHelpers.chart_series/1` builds those points in-memory from the history list (same reduce as `Matches.cumulative_win_rate/1` but without the DB query, sorting by `started_at` ascending), then delegates to `LiveHelpers.cumulative_winrate_series/1` for encoding. No duplication.

## Context Layer

No new query functions needed. `Matches.opponent_matches/2` already returns the full history ordered by `started_at desc`. The component receives the list as an assign — LiveViews already fetch it.

## Chart Implementation

The `cumulative_winrate` chart type is already implemented in the JavaScript Chart hook. The opponent panel uses the same type, passing:

```heex
<div
  :if={length(@history) >= 3}
  id={"#{@id}-chart"}
  phx-hook="Chart"
  data-chart-type="cumulative_winrate"
  data-series={OpponentHelpers.chart_series(@sorted_history)}
  class="min-h-[10rem] rounded-lg bg-base-300/40 mb-4"
/>

The show threshold matches the main matches dashboard: `length(history) > 2`.
```

The chart shows win rate trending over sequential encounters with this opponent — useful for seeing if you've adapted to a specific player over time.

## Testing

Per ADR-013 and the project's testing strategy:

- `OpponentHelpers` tests in `test/scry_2_web/live/opponent_helpers_test.exs`, `async: true`, using `build_match/1` factory
  - `record/1` — empty list, all wins, all losses, mixed
  - `win_rate/2` — zero matches (nil), 100%, 0%, fractional
  - `format_win_rate/1` — nil → "—", float → "67%"
  - `chart_series/1` — at least one golden example verifying series structure
  - `latest_rank/1` — nil list, list with ranks, list without ranks

- `OpponentComponents` render tests are not written (per the "never test rendered HTML" policy in CLAUDE.md)

- The existing `MatchesLive` integration tests continue to cover the show view; no new LiveView integration tests needed unless the show view was untested before

## Non-Goals

- No new database queries or Ecto changes
- No `Matches.opponent_stats/2` context function — computation belongs in the helper layer, not the context, since the data is already fetched
- No opponent-dedicated page (`/opponents/:name`) — that can be a future feature built on top of this component
- No format/BO filter on the history list — full history shown as-is
