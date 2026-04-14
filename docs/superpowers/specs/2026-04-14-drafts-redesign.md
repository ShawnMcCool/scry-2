# Drafts Redesign

**Date:** 2026-04-14  
**Status:** Approved

## Context

The current drafts view is minimal: a bare list (Started, Set, Format, W-L) and a detail view showing pack/pick/arena_id in a plain table. Several projection gaps exist — human draft events are never projected, `completed_at`/`wins`/`losses` are never populated, the card pool from `DraftCompleted` is discarded, and `format` is hardcoded as `"quick_draft"`. The LiveView doesn't use card images, has no stats, and no filters.

This redesign completes the projection layer for all five draft event types, adds cross-context wins/losses via PubSub, and rebuilds the UI to match the conventions established by the matches, economy, and decks views.

---

## List View (`/drafts`)

### Stats Dashboard (top)

Four stat cards using the existing `<.stat_card>` component:

| Stat | Notes |
|---|---|
| Total Drafts | Count of all drafts for the active player |
| Win Rate | Wins / (Wins + Losses) across all complete drafts |
| Avg Wins | Mean wins per complete draft |
| Trophies | Count of drafts where wins == 7 (max wins) |

Below the stat cards: a **Format Breakdown** widget (matching the matches page format widget). Three rows — Quick Draft, Premier Draft, Traditional Draft — each showing a win-rate progress bar and `XX% (N drafts)`. Color-coded: ≥55% emerald, 40–54% amber, <40% red.

### Filters

- **Format chips** (left): All Formats · Quick Draft · Premier Draft · Traditional Draft
- **Set chips** (right): derived from distinct `set_code` values in player's drafts, sorted by most recent
- URL params: `?format=quick_draft&set=FDN&page=1`

### List Table

Columns: Date · Set · Format · Record · Status

- **Record**: `7–2` colored by win rate (emerald/amber/red). Trophy badge (`🏆` label, amber chip) when wins == 7.
- **Status**: "Complete" (emerald) when `completed_at` is set; "In Progress" (amber) otherwise.
- Rows are clickable → navigate to `/drafts/:id`
- Pagination matching matches page pattern (page links, 50 per page)

---

## Detail View (`/drafts/:id`)

### Header (always visible)

- Set + Format label (e.g., "FDN Quick Draft")
- Date (`started_at`)
- Record: large W–L, Trophy badge if applicable
- "In Progress" label if `completed_at` is nil

### Tabs

Three tabs via URL param `?tab=picks|deck|matches`. Default: `picks`.

---

### Picks Tab

Renders the complete pick sequence, one section per pick.

Each section:
- Label: `Pack N · Pick N` (small, uppercase, muted)
- Card grid: all cards from `pack_arena_ids` rendered as `<.card_image>` at ~72px wide
  - **Picked card**: indigo border (`ring-2 ring-primary`) + checkmark badge (indigo circle, top-right corner)
  - **Passed cards**: `opacity-40`
- Cards use `<.card_image arena_id={...} name={...} />` — lazy loaded, hover preview

**Edge cases:**
- Pack 1 Pick 1 for human drafts has no pack contents (known MTGA gap — `Draft.Notify` skips the first pick). Render the picked card alone with a note: "Pack contents unavailable for first pick."
- Bot drafts always have full pack contents.

---

### Deck Tab

Two sections:

**Submitted Decks** (top)  
One card per submitted deck (linked to `/decks/:mtga_deck_id`):
- Deck name + mana color pips
- Counts: `N lands · N spells`
- Derived from matches for this draft event (queried via `Matches.list_decks_for_event/1`, a new context function)

**Full Draft Pool** (below)  
The complete `card_pool_arena_ids` from `DraftCompleted`, grouped by card type:
- Creatures · Instants & Sorceries · Artifacts & Enchantments · Lands
- Each group: type label + count header, then card images in a horizontal row (same `<.card_image>` component)
- Card type resolution via `Cards.get_type/1` (looks up `cards_cards.type_line`)
- If `card_pool_arena_ids` is nil (draft not yet complete), show empty state: "Pool available after draft is complete."

---

### Matches Tab

Matches for this draft event, queried via `Matches.list_matches_for_event/1` (new context function, filters by `event_name`).

Table columns: Result · Opponent (+ rank icon) · Deck (link to `/decks/:mtga_deck_id`) · Date

- Result: `W` (emerald) / `L` (red)
- Each row links to `/matches/:id` (match detail)
- Deck column links to `/decks/:mtga_deck_id` using `match.deck_name` as label

---

## Projection Changes

### Schema Migrations

**`drafts_drafts`** — two additions:
- `card_pool_arena_ids` — JSON array of integer arena_ids (nullable; nil until DraftCompleted fires)
- No new columns for wins/losses — they already exist but are currently never written

**`drafts_picks`** — three additions:
- `auto_pick` — boolean, nullable (Quick Draft only)
- `time_remaining` — float, nullable, seconds (Quick Draft only)
- `picked_arena_ids` — JSON array of integers, nullable (supports Pick Two format; for normal picks this is a single-element list; replaces overloading `pack_arena_ids` for this purpose)

### `DraftProjection` — complete all five event types

Currently only claims `draft_started` and `draft_pick_made`. Expand `@claimed_slugs` to all five:

**`draft_started`** (existing — no changes)

**`draft_pick_made`** (existing — add `auto_pick` and `time_remaining` to upsert attrs)

**`draft_completed`** (new handler):
- Update `drafts_drafts` row: set `card_pool_arena_ids`, `completed_at`, `format` (derived from event_name)
- Derive format: `QuickDraft_*` → `"quick_draft"`, `PremierDraft_*` → `"premier_draft"`, `TradDraft_*` → `"traditional_draft"`
- Do not set wins/losses here — they come from the matches cross-context listener

**`human_draft_pack_offered`** (new handler):
- Upsert `drafts_picks` row by `(draft_id, pack_number, pick_number)` with `pack_arena_ids`
- `picked_arena_id` left nil — will be filled by `human_draft_pick_made`
- Human drafts have no `DraftStarted` event. If no draft row exists yet for `mtga_draft_id`, create one with the data available (player_id, mtga_draft_id, format derived from event_name, set_code extracted from event_name, started_at = occurred_at). This is the only case where the draft row is created outside of `draft_started`.

**`human_draft_pick_made`** (new handler):
- Upsert `drafts_picks` row by `(draft_id, pack_number, pick_number)` with `picked_arena_id`
- `pack_arena_ids` preserved from any prior `human_draft_pack_offered` upsert (merge, don't overwrite)
- `picked_arena_ids` stored in the new `picked_arena_ids` JSON column (list; single-element for normal picks, multi-element for Pick Two)
- `pack_arena_ids` preserved from any prior `human_draft_pack_offered` upsert — merge, don't overwrite

### Format Derivation (fix existing bug)

Currently hardcoded `"quick_draft"` in the `draft_started` handler. Move format derivation to a shared private function called in both `draft_started` and `draft_completed`:

```
"QuickDraft_" prefix  → "quick_draft"
"PremierDraft_" prefix → "premier_draft"
"TradDraft_" prefix   → "traditional_draft"
fallback              → "unknown"
```

### Cross-Context Wins/Losses (PubSub listener)

`DraftProjection` subscribes to `Topics.matches_updates()` on startup. When a `{:match_updated, match_id}` broadcast arrives:
1. Load the match (via `Matches.get_match/1` — public API, no direct table access)
2. If `match.event_name` matches a known draft `event_name`, query win/loss totals for that event
3. Update the draft row: `wins = count(won == true)`, `losses = count(won == false)`
4. Broadcast `drafts:updates` so the LiveView refreshes

**Single publisher rule**: `DraftProjection` is the only writer to `drafts_drafts.wins`/`losses`. No other module sets these.

---

## Context API Changes

### `Scry2.Drafts` (new functions)

- `draft_stats(player_id)` — returns `%{total, win_rate, avg_wins, trophies, by_format}` for the dashboard
- `list_drafts(opts)` — extend existing: add `format:` and `set_code:` filter opts

### `Scry2.Matches` (new functions)

- `list_matches_for_event(event_name, player_id)` — returns matches filtered by event_name
- `list_decks_for_event(event_name, player_id)` — returns distinct deck submissions (mtga_deck_id, deck_name, colors) used in matches for this event

### `Scry2.Cards` (new function if not present)

- `get_type(arena_id)` — returns the `type_line` string for card grouping in the pool display

---

## LiveView Changes

### `DraftsLive`

**Index assigns**: `stats`, `by_format`, `drafts`, `format_filter`, `set_filter`, `page`

**Detail assigns**: `draft`, `picks`, `active_tab`, `card_pool`, `submitted_decks`, `matches`

- Tab switching via `handle_params/3` — URL param `?tab=picks|deck|matches`
- Only load tab data when that tab is active (lazy per-tab loading, same pattern as `DecksLive`)
- Subscribe to `Topics.drafts_updates()` — debounced reload on update

### `DraftsHelpers` (extend existing)

New pure functions:
- `format_label/1` — `"quick_draft"` → `"Quick Draft"` etc. (may already exist in `LiveHelpers`)
- `trophy?/1` — `draft.wins == 7`
- `win_rate/1` — float 0.0–1.0, nil if no games
- `group_pool_by_type/1` — groups `[arena_id]` into `[{type_label, [card]}]` using card type_line; categories: Creatures / Instants & Sorceries / Artifacts & Enchantments / Lands / Other

---

## Verification

1. **Reingest**: After implementing projection changes, call `Scry2.Events.reset_all!()` and restart the watcher. Verify bot draft picks reappear correctly.
2. **Human drafts**: Play or simulate a Premier Draft session. Confirm picks and pool appear.
3. **Wins/losses**: Complete a draft event (play matches). Confirm `wins`/`losses` update on the draft row via PubSub listener.
4. **Format derivation**: Verify Quick Draft, Premier Draft, Traditional Draft all show correct format labels.
5. **Picks tab**: Confirm card images render, picked card has indigo ring + checkmark, passed cards are dimmed.
6. **Deck tab**: Confirm pool groups by type, submitted deck links to correct `/decks/:id`.
7. **Matches tab**: Confirm match rows link to `/matches/:id`, deck column links to `/decks/:mtga_deck_id`.
8. **Stats dashboard**: Confirm trophy count, win rate, and format breakdown are accurate.
9. **`mix precommit`** passes with zero warnings.
