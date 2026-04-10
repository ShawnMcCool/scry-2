# Cards Page Redesign

## Problem Statement

The cards page was a minimal filtered table. It lacked visual card browsing, data source visibility, and import controls. Users had to go to the dashboard to trigger a 17lands refresh and had no UI for Scryfall backfill at all.

## Design Objectives

- Show cards visually — images in a grid, not rows in a table
- Provide immediate feedback from first keystroke or filter toggle
- Make data sources and storage legible at a glance
- Put import controls where they belong — on the cards page

## User-Facing Behavior

**Search and filter bar** always visible at the top. Text input + 7 mana color toggles (W/U/B/R/G/M/C) + filter drawer icon. No submit button — live results from every change.

**Card grid** appears below the search bar whenever any search or filter is active. Capped at 100 results with a count header. Empty by default; instructional text shows instead.

**Filter drawer** slides from the right when the sliders icon is clicked. Contains: Rarity, Mana Value (0–7+), Card Type (Creature/Instant/Sorcery/Enchantment/Artifact/Planeswalker/Land/Battle). All categories combine with AND; within a category, selections combine with OR.

**Data Sources panel** (bottom-left, 50% width): per-source rows with count, size, proportional bar. Sources: 17lands, Scryfall, Card Images. Refreshes on import completion.

**Import Controls panel** (bottom-right, 50% width): per-source Refresh buttons with last-updated timestamps and live status dots. Oban queue summary at bottom.

## Acceptance Criteria

- [ ] Search bar with text input and W/U/B/R/G/M/C mana color toggles renders at top of page
- [ ] No results on idle load; instructional copy explains how to search and filter
- [ ] Typing any text shows live results (debounced); color toggles filter by OR semantics; gold = multicolor only
- [ ] Results grid shows at most 100 cards; "Showing N of X — refine to see more" when capped
- [ ] Each result card shows: card image, name, rarity badge
- [ ] Filter drawer slides from right; Rarity, Mana Value, and Card Type sections present
- [ ] Card Type filter uses boolean `is_X` columns (fast, indexed, no LIKE scan)
- [ ] Data Sources panel shows per-table sizes via `dbstat` and image cache filesystem size
- [ ] Import Controls panel shows last-updated per source and Refresh button for each
- [ ] Refresh buttons enqueue correct Oban workers; status reflects in real-time
- [ ] 17lands Refresh button removed from Dashboard

## Anti-patterns

- **Result walls**: Hard cap at 100 with total count shown. Never return unbounded results.
- **Container prison**: Results flow naturally — not in a fixed-height scrollable box.
- **Hidden affordances**: Color toggles are always visible, not buried in the drawer.
- **Dashboard sprawl**: Import controls live here, not scattered on other pages.

## Deferred

- Collection filter (Collected / Not Collected)
- Card subtype filtering (Wizard, Elf, Forest, etc.)
- Format legality filter
- Sort controls
- Card detail modal on click

## Decisions

See `decisions/user-interface/2026-04-10-007-cards-page-redesign.md`
