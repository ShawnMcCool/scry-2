# Cards Page Redesign as Visual Browser

- Status: Accepted
- Date: 2026-04-10

## Context and Problem Statement

The cards page was a minimal filtered table with three inputs (name, rarity, set code) and a 200-row hard limit. It treated cards as raw data rows rather than the rich reference data they are. The page also lacked visibility into data sources and import controls — the only way to trigger a 17lands refresh was via the dashboard, and Scryfall backfill had no UI at all.

## Decision

Replace the cards page with a first-class visual card browser modelled after the MTGA in-game card search UX.

**Search and filter controls (always visible at top):**
- Dark pill text input with live search (debounced 150ms), × clear button
- Seven mana color toggle buttons inline using `mana_pip` component: W/U/B/R/G/M/C
  - OR semantics: selecting multiple colors broadens results
  - M = multicolor (cards with more than one color); C = colorless
  - Active state shown with `ring-2 ring-primary`
- Sliders icon button opens the filter drawer

**Filter drawer (slides from right, 360px wide):**
- Rarity toggles: Common / Uncommon / Rare / Mythic
- Mana Value pill toggles: 0 1 2 3 4 5 6 7+
- Card Type toggles: Creature / Instant / Sorcery / Enchantment / Artifact / Planeswalker / Land / Battle
- All filter categories combine via AND; within a category, selections combine via OR
- "Clear all" and × close

**Results area (shown when any filter or search is active):**
- Header: "Showing N of X cards" — appends "— refine to see more" when capped
- Hard cap of 100 results enforced at the context query level
- CSS grid: `auto-fill minmax(120px, 1fr)`, gap-2
- Each card cell: `card_image` component (portrait ratio), card name (text-xs, truncated, CardHover tooltip), `rarity_badge`

**Empty state (no search, no filters active):**
- Instructional text explaining search by name, color toggles, and the filter drawer
- Positioned between search bar and bottom panels

**Data Sources panel (left, 50% width):**
- Per-source row: source name, record count, table/file size, proportional bar
- Sources: 17lands (`cards_cards`), Scryfall (`cards_scryfall_cards`), Card Images (filesystem)
- Table sizes via `SELECT SUM(pgsize) FROM dbstat WHERE name = 'TABLE'`
- Image cache size via filesystem stat
- Summary footer: "Database: X MB · Image cache: Y MB"
- Reloads on `{:cards_refreshed, _}` PubSub message

**Import Controls panel (right, 50% width):**
- Two rows: 17lands card data, Scryfall arena IDs
- Per-row: source name, description, "Last updated: X" (from `MAX(updated_at)`), Refresh button, status dot
- Status dot: green (idle), orange (running), red (failed)
- Oban queue summary at bottom
- 17lands Refresh button removed from dashboard

**Schema additions required:**
Eight boolean type columns added to `cards_cards` for indexed type filtering:
`is_creature`, `is_instant`, `is_sorcery`, `is_enchantment`, `is_artifact`, `is_planeswalker`, `is_land`, `is_battle`.
Populated by the 17lands importer from the `types` string. Individual partial indexes on each column.

## Consequences

**Good:**
- Cards page is self-contained: browse, filter, understand data, trigger imports — all in one place
- Card type filtering uses indexed boolean columns instead of LIKE scans
- Import controls consolidated out of the dashboard
- Scryfall backfill gets its first UI control

**Neutral:**
- The 17lands Refresh button is removed from the dashboard; users must go to the cards page to trigger a refresh
- Empty state has instructional text even before collection filtering exists — will become more natural once collection data is available

**Deferred:**
- Collection filter (Collected / Not Collected) — revisit once collection data is tracked
- Card type subtype filtering (Wizard, Elf, Forest, etc.)
- Set-by-set browsing / format legality filter
- Sort controls (by name, mana value, rarity)
- Card detail modal on click

## Related

- DDR-001 (badge style conventions)
- DDR-006 (mana icon font — color toggles use `mana_pip` component)
- ADR-014 (arena_id stability — card images keyed on arena_id)
