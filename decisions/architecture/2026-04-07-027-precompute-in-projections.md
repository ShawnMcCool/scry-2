---
status: accepted
date: 2026-04-07
---
# Precompute derived data in projections, not at render time

## Context and Problem Statement

The mulligans page needs to display per-hand analytics: land count, mana curve distribution, color breakdown. Computing these at render time by joining to card metadata on every page load is wasteful — the hand composition doesn't change after ingestion.

More broadly, any data that can be computed once from a domain event and its context should be computed during projection, not deferred to the LiveView.

## Decision Outcome

**Precompute derived data during projection whenever the inputs are available and the result won't change.** Store the computed values as columns on the projection table.

### Rules

1. **Compute at projection time.** When the projector processes a domain event, it has access to the event data and can query reference tables (card metadata, match data). Compute derived fields here and store them in the projection row.

2. **Don't compute at render time.** LiveViews should read precomputed values from the projection, not re-derive them from raw data on every page load. This keeps LiveViews thin and page loads fast.

3. **Projection rebuilds recompute.** Since projections are disposable and rebuildable from the event log (`replay_projections!/0`), precomputed values are always recoverable. If the computation logic changes, replay and all rows get the new values.

4. **Exception: when inputs aren't available at projection time.** Some derived data depends on context that the projector doesn't have (e.g., draft win rates that depend on future match outcomes). These must be computed lazily or updated by a later event.

5. **Exception: when the computation is trivial and the data is tiny.** Counting 7 items in a list is fine at render time. But even simple computations should move to the projection if they'd run on every page load for every row.

### Examples

- **Land count in a mulligan hand** → precompute: the hand and card types are known at ingestion time
- **Mana curve distribution** → precompute: CMC values are in the card database
- **Color distribution** → precompute: card colors are in the card database
- **Win rate by archetype** → compute lazily: depends on future match outcomes

### Consequences

* Good, because page loads are fast — no per-row computation
* Good, because projection replays automatically recompute — logic changes propagate
* Good, because LiveViews stay thin — just read and render
* Neutral, because projection tables have more columns — but storage is cheap and reads are fast
* Neutral, because projectors need access to card metadata at projection time — they already have DB access
