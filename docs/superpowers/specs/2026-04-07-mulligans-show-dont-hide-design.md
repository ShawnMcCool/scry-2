# Mulligans View — Show Don't Hide Redesign

## Problem

The current mulligans view displays card hands as rows of numeric arena_id badges in a table. The user has to mentally translate IDs to cards. Per UI-004 (Show Don't Hide), the actual card images should be visible at a glance.

## Design

Replace the table layout with a card-row layout. Each hand is a horizontal row showing:

1. **Keep/Mulligan badge** on the left — orange-bordered "Keep" or blue-bordered "Mulligan"
2. **Card images inline** — small card art via `<.card_hand>` component
3. **Hand size** on the right — subtle count label

Hands are grouped by match (existing `group_by_match` logic), newest match first.

### Visual Treatment

- Each hand row has a **colored left border accent**: `border-l-3 border-warning` (orange) for Keep, `border-l-3 border-info` (blue) for Mulligan
- Subtle `bg-base-200/50` background on each row with rounded corners
- Badge uses DaisyUI's `badge-warning` (Keep) and `badge-info` (Mulligan) with outlined style for elegance
- Card images at `w-12` (48px wide) — small enough to fit 7 cards comfortably, large enough to recognize the art
- `gap-1` between cards for tight but readable spacing
- Match header: small uppercase label + truncated match ID link (existing pattern)

### Data Flow

1. `handle_params` loads mulligans via `Events.list_mulligans(player_id:)`, groups by match
2. Collects all `hand_arena_ids` across all hands
3. Calls `ImageCache.ensure_cached(all_arena_ids)` to pre-cache images
4. Template renders match groups with `<.card_hand>` components

### Badge Colors (per UI-004)

- **Keep** — orange (`badge-warning`, `border-warning`)
- **Mulligan** — blue (`badge-info`, `border-info`)

### Changes to Helpers

Update `decision_badge_class/1`:
- `:kept` → `"badge-warning badge-outline"`
- `:mulliganed` → `"badge-info badge-outline"`

Update `decision_border_class/1` (new):
- `:kept` → `"border-warning"`
- `:mulliganed` → `"border-info"`

### Files

| File | Action | Change |
|------|--------|--------|
| `lib/scry_2_web/live/mulligans_live.ex` | Modify | Replace table with card-row layout, add ensure_cached call |
| `lib/scry_2_web/live/mulligans_helpers.ex` | Modify | Update badge classes, add border class helper |
| `test/scry_2_web/live/mulligans_helpers_test.exs` | Modify | Update badge class assertions, add border class tests |
