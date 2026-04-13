# Deck Analysis Tab

## Context

The deck detail page (`/decks/:deck_id`) has three tabs: Overview, Matches, Versions. There's also a standalone mulligans page (`/mulligans`) that shows every opening hand chronologically — useful for browsing, but not for answering strategic questions like "should I keep 2-land hands with this deck?"

This feature adds an **Analysis** tab to the deck page that provides decision-oriented analytics. The first implementation focuses on mulligan analytics and card-level performance metrics. The tab name and section-based layout are designed to expand with matchup analysis, sideboard analytics, and other sections in future iterations.

As part of this work, the standalone Mulligans context and page are removed. Mulligan data becomes a Decks-owned projection, scoped by deck — where it belongs architecturally.

## Scope

### In scope
- New "Analysis" tab on the deck detail page
- Mulligan analytics section (hand-size x land-count heatmap, keep rates, win rates)
- Card performance section (OH WR, GIH WR, GD WR, GND WR, IWD per card)
- Move mulligan projection under Decks context (`decks_mulligan_hands`)
- Add CardDrawn projection under Decks context (`decks_cards_drawn`)
- Enhance `CardDrawn` domain event with `game_number`
- Delete standalone Mulligans context, page, route, helpers

### Out of scope (future)
- 17lands community metrics comparison (design extension points only)
- Matchup analysis section (win rate by opponent colors/archetypes)
- Sideboard analytics section
- Full game replay / zone state tracking
- Projecting other gameplay events (SpellCast, LandPlayed, etc.)

## Architecture

### Move mulligan projection under Decks

The Mulligans bounded context (`Scry2.Mulligans`) is deleted. Its projection table `mulligans_mulligan_listing` is replaced by `decks_mulligan_hands`, owned by the Decks context. The `DeckProjection` module expands to claim `mulligan_offered` events.

**Rationale:** Mulligan data is only meaningful in the context of a specific deck. The standalone page showed all hands chronologically with no deck grouping — not useful for analysis. Moving under Decks means deck-scoped queries stay within `decks_*` tables per ADR-031.

### Add CardDrawn projection

The `CardDrawn` domain event already exists and fires from GRE annotation parsing, but no projector claims it. A new `decks_cards_drawn` table captures which cards were drawn per game, enabling the full suite of 17lands-style card-level metrics.

**Key insight:** Opening hand cards may or may not produce "Draw" annotations in the GRE (depends on MTGA's internal handling). Opening hand composition is authoritatively captured by `decks_mulligan_hands` (from `MulliganOffered` events). The `decks_cards_drawn` table captures mid-game draws. Card performance queries combine both sources:

- **Opening hand cards**: `decks_mulligan_hands` where `decision = "kept"` → `hand_arena_ids`
- **Cards drawn during game**: `decks_cards_drawn`
- **Cards never seen**: deck composition minus (opening hand union drawn)

### DeckProjection expansion

`DeckProjection` currently claims: `deck_updated`, `deck_submitted`, `match_created`, `match_completed`, `game_completed`.

Expanded to also claim: `mulligan_offered`, `card_drawn`.

Stamping logic:
- `DeckSubmitted` → backfills `mtga_deck_id` on `mulligan_hands` and `cards_drawn` rows for the match (handles event ordering: MulliganOffered fires before DeckSubmitted)
- `MatchCreated` → stamps `event_name` on `mulligan_hands`
- `MatchCompleted` → stamps `match_won` on both `mulligan_hands` and `cards_drawn`

## Data Model

### `decks_mulligan_hands` table

Replaces `mulligans_mulligan_listing`. Scoped by `mtga_deck_id`.

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigserial | PK |
| `mtga_deck_id` | string | Nullable initially, backfilled from DeckSubmitted |
| `mtga_match_id` | string | NOT NULL |
| `seat_id` | integer | |
| `hand_size` | integer | NOT NULL — 7, 6, 5... |
| `hand_arena_ids` | map | `%{"cards" => [arena_id, ...]}` |
| `land_count` | integer | Enriched at ingestion (ADR-030) |
| `nonland_count` | integer | |
| `total_cmc` | float | |
| `cmc_distribution` | map | |
| `color_distribution` | map | |
| `card_names` | map | |
| `event_name` | string | Stamped from MatchCreated |
| `decision` | string | `"kept"` or `"mulliganed"` |
| `match_won` | boolean | Stamped from MatchCompleted |
| `occurred_at` | utc_datetime | NOT NULL |
| `inserted_at` / `updated_at` | utc_datetime | |

- Unique constraint: `[:mtga_match_id, :occurred_at]`
- Index: `[:mtga_deck_id]`

London mulligan logic (same as existing): when a new MulliganOffered arrives, all prior hands for that match are stamped `"mulliganed"`. The new hand is inserted as `"kept"` (tentative until next offer).

### `decks_cards_drawn` table

One row per card draw event during a game.

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigserial | PK |
| `mtga_deck_id` | string | Nullable initially, backfilled from DeckSubmitted |
| `mtga_match_id` | string | NOT NULL |
| `game_number` | integer | From enhanced CardDrawn event |
| `card_arena_id` | integer | |
| `card_name` | string | Enriched at ingestion |
| `turn_number` | integer | |
| `match_won` | boolean | Stamped from MatchCompleted |
| `occurred_at` | utc_datetime | NOT NULL |
| `inserted_at` / `updated_at` | utc_datetime | |

- Unique constraint: `[:mtga_match_id, :game_number, :card_arena_id, :occurred_at]`
- Indexes: `[:mtga_deck_id]`, `[:mtga_deck_id, :card_arena_id]`

### CardDrawn event enhancement

Add `:game_number` field to `Scry2.Events.Gameplay.CardDrawn` struct and `from_payload/1`. Thread `match_context[:current_game_number]` into the `common` map in `build_turn_actions/4` at `identify_domain_events.ex:1562`.

Existing events in the store lack `game_number` — they deserialize with `nil`. Reingest populates the field. Projection treats nil as game 1 (safe default).

## Analysis Tab — UI Design

Fourth tab on the deck detail page: Overview | Matches | Versions | **Analysis**

URL: `/decks/:deck_id?tab=analysis`

### Section 1: Mulligan Analytics

**Layout A** (stats + matrix + chart):

**Headline stat cards** (top row):
- Total hands seen
- Keep rate (% of hands kept on first offer)
- Win rate when keeping on 7

**Hand profile heatmap** (center):
- Rows: hand size (7, 6, 5)
- Columns: land count (0, 1, 2, 3, 4, 5, 6, 7)
- Each cell: sample count + win rate, color-coded (green > 55%, yellow 45-55%, red < 45%, grey = no data)
- Only shows cells where `decision = "kept"` — answering "when I keep hands like this, do I win?"

**Win rate by land count chart** (bottom):
- Bar chart showing win rate for each land count in kept hands
- Sample size shown per bar

### Section 2: Card Performance

Table showing per-card metrics computed from personal data:

| Column | Source | Description |
|--------|--------|-------------|
| Card | card_names from mulligan/draw data | Card name |
| Copies | deck composition | Count in current deck list |
| OH WR | mulligan_hands (kept) | Win rate when card is in opening hand |
| GIH WR | mulligan_hands + cards_drawn | Win rate when card was drawn at any point |
| GD WR | cards_drawn only | Win rate when drawn during game (not opener) |
| GND WR | total games minus GIH games | Win rate when card was never drawn |
| IWD | GIH WR - GND WR | Improvement when drawn (pp) |
| Games | count | Sample size for GIH WR |

- Sorted by IWD descending (strongest performers first)
- IWD color-coded: green positive, red negative
- Sample sizes shown inline — noisy metrics with < 5 games get a warning indicator
- Empty state message when insufficient data

**Statistical honesty:** With ~20-50 games per deck, per-card metrics are noisy. The UI:
1. Shows sample sizes prominently next to every percentage
2. Dims or marks metrics with fewer than 5 data points
3. Uses relative ranking within the deck rather than absolute thresholds

### Extension point: 17lands community comparison

The card performance query returns a map with a `:community` key (nil for now). When the 17lands analytics import is added, this key populates with community OH WR, GIH WR, etc. per card per set/format. The table gains a "vs Community" column showing the delta.

## Query Functions

### `Decks.mulligan_analytics(mtga_deck_id)`

Returns:
```elixir
%{
  total_hands: integer,
  total_keeps: integer,
  keep_rate: float | nil,
  win_rate_on_7: float | nil,
  by_hand_size: [%{hand_size: integer, total: integer, keeps: integer, keep_rate: float}],
  by_land_count: [%{land_count: integer, total: integer, wins: integer, win_rate: float}]
}
```

### `Decks.mulligan_heatmap(mtga_deck_id)`

Returns a list of cells for kept hands:
```elixir
[%{hand_size: 7, land_count: 3, count: 12, wins: 8, win_rate: 66.7}, ...]
```

### `Decks.card_performance(mtga_deck_id)`

Returns per-card metrics combining mulligan hands and cards drawn:
```elixir
[%{
  card_arena_id: integer,
  card_name: string,
  copies: integer,
  oh_wr: float | nil,
  oh_games: integer,
  gih_wr: float | nil,
  gih_games: integer,
  gd_wr: float | nil,
  gd_games: integer,
  gnd_wr: float | nil,
  gnd_games: integer,
  iwd: float | nil,
  community: nil  # extension point
}, ...]
```

**Computation logic:**
1. From `decks_mulligan_hands` where `mtga_deck_id` and `decision = "kept"`: extract per-card opening hand presence and `match_won`
2. From `decks_cards_drawn` where `mtga_deck_id`: extract per-card draw events and `match_won`
3. From `decks_match_results` where `mtga_deck_id` and `won IS NOT NULL`: total completed games
4. Combine: GIH = opening hand union drawn. GND = total games minus GIH games. Compute rates.

## Files to Modify

### New files
- `lib/scry_2/decks/mulligan_hand.ex` — Ecto schema
- `lib/scry_2/decks/game_draw.ex` — Ecto schema for `decks_cards_drawn` (named for domain purpose, avoids collision with `Events.Gameplay.CardDrawn`)
- `lib/scry_2_web/live/decks_analysis_helpers.ex` — pure helper functions for the analysis tab
- `priv/repo/migrations/TIMESTAMP_create_deck_analysis_tables.exs`
- `test/scry_2/decks/deck_analysis_test.exs`

### Modified files
- `lib/scry_2/events/gameplay/card_drawn.ex` — add `:game_number` field
- `lib/scry_2/events/identify_domain_events.ex` — thread `game_number` into common map
- `lib/scry_2/decks/deck_projection.ex` — claim `mulligan_offered` and `card_drawn`, add project clauses, add stamp logic to existing handlers
- `lib/scry_2/decks.ex` — add write helpers and query functions
- `lib/scry_2_web/live/decks_live.ex` — add Analysis tab (parse_tab, tab_link, lazy loading, render)
- `lib/scry_2_web/live/decks_helpers.ex` — may need minor additions for shared formatting

### Deleted files (cleanup phase)
- `lib/scry_2/mulligans.ex`
- `lib/scry_2/mulligans/mulligan_listing.ex`
- `lib/scry_2/mulligans/mulligan_projection.ex`
- `lib/scry_2_web/live/mulligans_live.ex`
- `lib/scry_2_web/live/mulligans_helpers.ex`
- `test/scry_2_web/live/mulligans_helpers_test.exs`
- Any other mulligans-related test files
- Route in `router.ex`, nav link, ProjectorRegistry entry

### Migration to drop old table (after verification)
- `priv/repo/migrations/TIMESTAMP_drop_mulligans_tables.exs`

## Verification

1. `mix test` — all existing tests pass after changes
2. New tests pass for schemas, projection, queries, and helpers
3. `mix precommit` — zero warnings
4. Replay projections via Operations page — `decks_mulligan_hands` and `decks_cards_drawn` populate correctly
5. Check via tidewave logs — no errors during projection replay
6. Visit `/decks/:deck_id?tab=analysis` — mulligan heatmap renders with correct data
7. Card performance table shows metrics with sample sizes
8. Verify `/mulligans` route returns 404 after cleanup
9. Verify no references to Mulligans context remain in codebase
