---
status: accepted
date: 2026-04-07
---
# Page-specific projections over shared monolithic projections

## Context and Problem Statement

The mulligans page needs mulligan hands grouped by event and game, with match metadata (event name, format) joined in. Pulling this from the general-purpose `matches_matches` table and the raw domain event log requires ad-hoc joins in the LiveView's data loading function. This couples the UI to the shape of projections designed for other use cases.

As the app grows, each page will need data shaped differently — the matches list page needs win/loss summaries, the draft page needs pick sequences, the mulligans page needs hands grouped by event. Forcing all pages to query from the same shared projections creates complex, brittle data loading logic in LiveViews.

## Decision Outcome

Each page that displays projected data should have its own **read-optimized projection** — a schema and query layer designed for that page's specific read pattern. Projections are cheap (they're derived from the domain event log and can be rebuilt). Optimizing for read performance and UI simplicity is more valuable than avoiding a few extra tables.

### Rules

1. **Design the schema for the read pattern.** The mulligans projection should store hands pre-grouped with the event name and game number already joined, not require the LiveView to assemble this from multiple tables at render time.

2. **Projections are disposable.** Any projection table can be dropped and rebuilt from the domain event log via `Events.replay_projections!/0`. This makes it safe to change projection schemas as UI needs evolve.

3. **Projections subscribe to `domain:events`.** Each projection is an `UpdateFromEvent` GenServer that consumes domain events and writes to its own tables. This is the existing pattern used by `Matches.UpdateFromEvent` and `Drafts.UpdateFromEvent`.

4. **No shared "master" projection.** Don't build one large denormalized table that every page queries with different filters. Each page gets exactly the data it needs in exactly the shape it needs.

5. **LiveViews stay thin.** The LiveView's `load_*` function should be a simple context call, not a multi-table join assembler. If the data loading is complex, the projection schema is wrong.

### Consequences

* Good, because LiveViews have simple, fast data loading — one query, one shape
* Good, because projection schemas can evolve independently per page without affecting other pages
* Good, because projections are disposable and rebuildable — schema changes are cheap
* Neutral, because more tables exist — but they're small, indexed, and read-optimized
* Neutral, because each new page may need a new projection — but the UpdateFromEvent pattern is mechanical
