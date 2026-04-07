---
status: accepted
date: 2026-04-07
---
# Projections are durable in SQLite by default

## Context and Problem Statement

Projections are derived from the domain event log and can always be rebuilt via `replay_projections!/0`. This makes them logically disposable. However, "can be rebuilt" does not mean "should be rebuilt on every restart."

Replaying projections requires reprocessing every domain event through every projector — a process that scales with the total event count and involves per-event card metadata lookups, match context resolution, and other computation. For a user with thousands of games, this takes meaningful time. Forcing a replay on every application start would make cold starts slow and waste work that was already done.

## Decision Outcome

**Projections are persisted to SQLite tables by default.** They survive application restarts, BEAM crashes, and system reboots. Replay is an explicit recovery operation, not a startup routine.

### Rules

1. **Persist by default.** Every projection table lives in the same SQLite database as the domain event log. Rows written by projectors are durable immediately.

2. **Replay is for recovery, not startup.** `replay_projections!/0` exists for when projection logic changes or data needs regeneration. It is not called during normal application boot.

3. **Projectors are idempotent.** Replaying the same event twice produces the same row state (via upsert). This makes replay safe but doesn't make it free — the DB writes still cost time.

4. **No in-memory-only projections.** ETS, Agent, or process-state projections that vanish on restart are not used for data that the UI depends on. If a page needs data, it's in SQLite.

5. **Exception: ephemeral caches.** Short-lived caches (like the console log ring buffer) that are explicitly designed to be lost on restart are fine. These are not projections — they don't derive from the event log.

### Consequences

* Good, because application startup is fast — no replay needed
* Good, because projections survive crashes without data loss
* Good, because SQLite handles durability, concurrency, and indexing
* Neutral, because the database file grows with projection data — acceptable for a single-user desktop app
* Neutral, because projection schema changes require a migration + replay — but this is the standard Ecto workflow
