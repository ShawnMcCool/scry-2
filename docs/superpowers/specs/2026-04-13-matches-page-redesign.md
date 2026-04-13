# Matches Page Redesign

## Context

The `/matches` page is currently a flat list of the last 100 matches with a bare detail view. It needs to become the primary match analytics page — a dashboard with aggregate stats and charts at the top, a filtered match journal below, and a rich detail view when drilling into individual matches. The decks > matches tab is the proven reference for match display patterns, chart integration, and data loading.

Key constraint: maximize reusable components. Many patterns from DecksLive (date grouping, format helpers, chart series builders, match row layout) should be extracted into shared modules rather than duplicated.

## Page Structure

### Dashboard Section (top)

**Stat cards row** — horizontal row of `stat_card/1` components (already exists in CoreComponents):
- Total matches (count)
- Overall win rate (percentage, color-coded by threshold)
- Avg turns per match
- Avg mulligans per match
- Play/Draw win rate split (two values in one card)

**Chart + format breakdown (side by side):**
- Left (2/3 width): Cumulative win rate line chart using the existing `cumulative_winrate` chart type. Same pattern as decks page — ISO 8601 timestamps, percentage, tooltip with "NW–ML" record. Only shown when > 2 data points exist.
- Right (1/3 width): Format breakdown — horizontal progress bars showing win rate per format with record counts. Color-coded by threshold (green > 55%, yellow 45–55%, red < 45%).

All dashboard stats reflect the active filters. When a filter is applied, stats and chart update to show only the filtered subset.

### Filter Bar (divider between dashboard and list)

Sits between dashboard and match list as a visual divider.

**Filters (all as URL params for shareability and refresh persistence):**
- **Format:** "All Formats" chip + one chip per format present in data. Active chip is highlighted. Clicking a format chip filters to that format only.
- **BO1/BO3:** Toggle between best-of-one and best-of-three. Derived from `format_type` ("Traditional" = BO3) and `num_games`.
- **Result:** W/L toggle — show only wins or only losses.

All filters compose (format + BO type + result). Changing any filter updates the dashboard stats, chart, and match list together.

### Match List (below filters)

**Date grouping:** Matches grouped under date headers — "Today", "Yesterday", or formatted date (e.g., "April 10"). Reuse `group_matches_by_date/1` (extract from DecksHelpers to shared module).

**Pagination:** 20 matches per page with numbered page links. Same pattern as decks page.

**Match row contents:**
- Result letter (W/L) with color coding
- Opponent name + rank icon (if available)
- Deck colors (mana pips) + deck name
- Format badge (humanized event name)
- Game score for BO3 ("2–1") or play/draw indicator for BO1
- Timestamp (relative or "Apr 06 · 19:36")

Clicking a row navigates to `/matches/:id`.

### Detail View (`/matches/:id`)

**Rich match header:**
- Large result indicator (W/L)
- Opponent screen name
- Format + BO type + game score
- Timestamp + duration (formatted from `duration_seconds`)
- Deck colors (mana pips) + deck name
- Player rank at time of match (from `player_rank`)
- Back link to `/matches` (preserving filter state)

**Game-by-game breakdown:**
- Horizontal cards, one per game
- Each card: game number, result (W/L), play/draw, turns, mulligans
- Visual styling rather than raw table

**Submitted deck list:**
- Main deck + sideboard from `matches_deck_submissions`
- Card names resolved via `arena_id` join to `cards_cards` table
- Simple sorted list with counts (e.g., "4x Lightning Bolt"), grouped into main deck and sideboard sections

**Opponent history:**
- Query all matches against this `opponent_screen_name`
- Display overall record: "You are 3–1 against [opponent]"
- List previous matches with result, format, date — each clickable

## Data Layer Changes

### Matches Context (`lib/scry_2/matches.ex`)

**Extend `aggregate_stats/1`** to accept filter options:
- `:format` — filter by specific format
- `:format_type` — filter by "Traditional" (BO3) or non-Traditional (BO1)
- `:won` — filter by result (true/false)
- These compose with the existing `:player_id` filter

**New functions:**
- `cumulative_win_rate(opts)` — returns list of `%{timestamp, win_rate, wins, total}` for the cumulative win rate chart, respecting the same filter options. Similar to `Decks.cumulative_win_rate/1`.
- `opponent_matches(opponent_screen_name, opts)` — returns all matches against a specific opponent, excluding a given match ID. For the opponent history section.
- `format_counts(opts)` — returns map of format → count for filter badge display. Respects BO type and result filters.
- `list_matches(opts)` — extend to accept `:format`, `:format_type`, `:won`, `:offset` for filtering and pagination.

### No Projection Changes Needed

All dashboard stats are computed at read time from the existing `matches_matches` table. The projection already stamps all needed fields (`won`, `format`, `format_type`, `num_games`, `on_play`, `total_mulligans`, `total_turns`, `deck_colors`, `deck_name`, `duration_seconds`, `player_rank`, `game_results`). No new columns or projection logic required.

The cumulative win rate and aggregate stats are fast enough as read-time queries over the matches table (indexed on `started_at`, `format`). If performance becomes an issue later, these can be materialized, but SQLite handles this volume easily.

## Component Extraction

**Extract from DecksHelpers to shared module (`LiveHelpers` or new `MatchDisplayHelpers`):**
- `group_matches_by_date/1` — date grouping with Today/Yesterday labels
- `relative_time/1` — "2h ago", "3d ago" formatting
- `format_date/1` — human-readable date
- `win_rate_class/1` — Tailwind color class by win rate threshold
- `format_win_rate/1` — percentage formatting (trim trailing .0)
- `record_str/2` — "NW–ML" format string
- `cumulative_winrate_series/1` — JSON encoding for chart data
- `format_game_results/1` — per-game detail extraction from game_results map
- `match_score/1` — "2–1" score for BO3

**Already shared (no changes needed):**
- `stat_card/1` in CoreComponents
- `result_badge/1`, `rank_icon/1`, `mana_pips/1`, `empty_state/1`, `back_link/1` in CoreComponents
- `format_event_name/1` in CoreComponents
- `schedule_reload/2`, `format_label/1` in LiveHelpers
- `cumulative_winrate` chart type in chart.js

**Consolidate MatchesHelpers:**
- Keep `result_letter/1`, `result_letter_class/1`, `format_match_datetime/1`, `game_score/2`, `on_play_label/1`
- Remove `result_class/1` and `result_label/1` (duplicates of CoreComponents `result_badge`)

## URL Structure

```
/matches                                          # all matches, no filters
/matches?format=premier_draft                     # filtered by format
/matches?format=premier_draft&bo=3                # format + BO3
/matches?format=premier_draft&bo=3&result=won     # format + BO3 + wins only
/matches?page=2                                   # pagination
/matches/:id                                      # detail view
```

## Verification

1. **Dashboard stats correctness:** Apply each filter combination and verify stat cards, chart, and format breakdown update correctly. Cross-check against `Matches.aggregate_stats/1` in IEx.
2. **Filter composition:** Verify format + BO + result filters compose correctly — each narrows the result set.
3. **Chart rendering:** Cumulative win rate chart appears when > 2 matches, disappears when filtered to <= 2. Verify tooltip shows correct "NW–ML" record.
4. **Pagination:** Navigate pages, verify correct offset. Changing filters resets to page 1.
5. **Detail view:** Click a match row, verify header, game cards, deck list, and opponent history all render. Verify back link returns to `/matches` with filters preserved.
6. **Real-time updates:** Play a match in MTGA, verify the matches page updates via PubSub (debounced reload).
7. **Empty states:** Verify empty state renders when no matches exist or filters produce zero results.
8. **Component reuse:** Verify extracted helpers are used by both DecksLive and MatchesLive — no duplicated logic.
9. Run `mix precommit` — zero warnings, all tests pass.
