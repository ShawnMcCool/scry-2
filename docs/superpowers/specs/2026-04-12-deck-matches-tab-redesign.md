# Deck Matches Tab Redesign

## Context

The deck detail matches tab currently displays a flat table with 7 columns (Date, Result, Format, Event, Rank, Games, On Play). Every column has equal visual weight, making it hard to scan quickly. BO1 and BO3 matches are interleaved despite being fundamentally different formats. Event names show raw MTGA identifiers like "Traditional_Ladder". The goal is to make this tab a fast "glance and get out" reference — did I win, what happened, move on.

## Design

### BO1/BO3 Format Switcher

A `BO3 | BO1` toggle at the top of the matches tab, driven by the `format` query parameter (e.g., `?tab=matches&format=bo3`).

- **Default selection:** whichever format was played most recently for this deck. Determined by comparing the `started_at` of the newest BO1 and BO3 match.
- **Greyed/disabled state:** if a format has zero matches, its button is visually muted and not clickable.
- **Empty state:** when the selected format has no matches, show an attractive empty state (no table, just a centered message).
- Updates query string on toggle for direct linking. Uses `push_patch` for LiveView navigation.

### Date-Grouped Layout

Remove the Date column. Instead, group matches under date headers:

- **Today**, **Yesterday**, or the date (e.g., **April 10**) as a spanning row header.
- Matches within each date group are ordered newest-first.
- Date headers reduce per-row data by one column and create natural visual rhythm.

### BO3 Table Columns

| Column | Content |
|--------|---------|
| **Result** | "Win 2–1", "Loss 0–2" — explicit text result + match score |
| **Games** | Stacked per-game lines, one per game played |
| **Event** | Humanized event name (see below) |
| **Rank** | Rank icon (existing `<.rank_icon>` component) + rank text |

Each game line in the Games column:

```
W play
L draw · mull ×1
W play · mull ×2
```

- W/L is color-coded (green/red).
- "play" / "draw" (not "on play" / "on draw").
- Mulligan count shown only when > 0, as `· mull ×N`.

### BO1 Table Columns

| Column | Content |
|--------|---------|
| **Result** | "Win" or "Loss" — no score needed |
| **Play / Draw** | "play" or "draw", with `· mull ×N` inline when applicable |
| **Event** | Humanized event name |
| **Rank** | Rank icon + rank text |

No Games column — single game, so play/draw and mulligans go in their own column.

### Event Name Humanization

Use the existing `EnrichEvents.infer_format/1` combined with the deck's `format` field:

- `"Traditional_Ladder"` + deck format `"Standard"` → **"Ranked Standard"**
- `"Ladder"` + `"Standard"` → **"Standard Ladder"**
- `"DirectGame"` → **"Direct Challenge"**
- Draft events: use `format_event_name/1` which extracts set codes (e.g., "Quick Draft — FDN").

Build a helper that combines these for the deck matches context.

### Rank Display

Use the existing `<.rank_icon>` component (PNG images at `/images/ranks/`) alongside rank text. Pass `format_type` based on the match's format to select constructed vs limited icons.

### Pagination

- **20 matches per page.**
- Use the existing offset/limit pattern (`{results, total_count}` tuple from the context).
- Page number in query string: `?tab=matches&format=bo3&page=2`.
- Show "Showing 1–20 of 47 matches" text + page number buttons.
- Page resets to 1 when switching formats.

## Data Changes

### Enrich `game_results` in DeckProjection

The `DeckProjection` currently stores per-game data as:

```elixir
%{"game" => 1, "won" => true, "on_play" => true}
```

Add `num_mulligans` from the `GameCompleted` event (which already carries this field):

```elixir
%{"game" => 1, "won" => true, "on_play" => true, "num_mulligans" => 0}
```

**File:** `lib/scry_2/decks/deck_projection.ex` — the `handle_game_completed` clause that accumulates game results.

This is the only data change needed. No new tables, no cross-context joins, no new events.

After deploying, run `Scry2.Events.replay_projections!/0` to backfill existing match results with mulligan counts.

### Pagination in Decks Context

Add pagination support to `list_matches_for_deck/1`:

```elixir
def list_matches_for_deck(mtga_deck_id, opts \\ []) do
  limit = Keyword.get(opts, :limit, 20)
  offset = Keyword.get(opts, :offset, 0)
  format = Keyword.get(opts, :format)  # "bo1" or "bo3"

  # filter by format_type, order by started_at desc
  # return {matches, total_count}
end
```

## Files to Modify

| File | Change |
|------|--------|
| `lib/scry_2/decks/deck_projection.ex` | Add `num_mulligans` to `game_results` map in `GameCompleted` handler |
| `lib/scry_2/decks.ex` | Add pagination + format filter to `list_matches_for_deck/1` |
| `lib/scry_2_web/live/decks_live.ex` | Format switcher, pagination params, BO1/BO3-specific table rendering |
| `lib/scry_2_web/live/decks_helpers.ex` | Event name humanization helper, date grouping helper |

## Verification

1. **Projection enrichment:** Replay projections, verify `game_results` includes `num_mulligans` for all games.
2. **BO3 view:** Verify game lines show W/L, play/draw, and mulligan counts per game.
3. **BO1 view:** Verify simplified columns with play/draw + mulligans inline.
4. **Format switcher:** Verify URL updates, default selection logic, disabled state when no matches exist.
5. **Date headers:** Verify correct grouping with "Today", "Yesterday", and date labels.
6. **Event names:** Verify "Traditional_Ladder" → "Ranked Standard", "Ladder" → "Standard Ladder", etc.
7. **Pagination:** Verify 20-per-page, page navigation, page reset on format switch.
8. **Empty state:** Verify attractive empty state when a format has no matches.
9. **Rank icons:** Verify rank PNG icons display correctly next to rank text.
