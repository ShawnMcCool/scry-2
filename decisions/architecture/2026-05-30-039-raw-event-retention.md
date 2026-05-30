---
status: accepted
date: 2026-05-30
---
# 039. Raw event retention — bounded, prunable, never a silent data-loss path

## Status

Accepted

## Context and Problem Statement

Scry2 persists every parsed MTGA log event verbatim in `mtga_logs_events`
(`raw_json` column) before any downstream processing touches it (ADR-015).
This raw store is the project's deepest data-integrity guarantee: if the
translation layer (`Scry2.Events.IdentifyDomainEvents`) ever changes, the
entire domain event log can be regenerated from raw via
`Events.reingest!/0` / `Events.retranslate_from_raw!/0`.

ADR-015 estimated this would cost "a few MB/month." Measured reality
(2026-05-30) is ~100× that: 1.8 GB of raw JSON over ~7.5 weeks, of which
`GreToClientEvent` (the in-match play-by-play stream) is ~70%. The raw
store is 76% of the whole database.

This raised the question of whether raw events must be kept forever. The
research conclusion:

1. **Projections do not depend on raw.** Every projection rebuild
   (`Events.replay_projections!/0`) reads `domain_events` only. The 378k
   domain events (72 MB) are sufficient to rebuild every match, deck,
   draft, and stat. Raw is touched by exactly two paths: initial
   ingestion (each event once) and retranslation.

2. **Raw is therefore a bounded retranslation hedge, not a permanent
   dependency.** Its only irreplaceable role is re-extracting *new* fields
   from MTGA's wire format when the translator learns something new. That
   capability only needs to reach back as far as you would realistically
   re-extract — not to the beginning of time.

3. **There is a latent data-loss bomb in the retranslation path.**
   `reingest!/0`, `retranslate_from_raw!/0`, `reset_all!/0`, and
   `Operations.reingest_with_progress/0` all **delete every domain event
   first, then rebuild from whatever raw survives**. Today this is safe
   only because raw is complete. The day any retention policy prunes old
   raw, "rebuild from surviving raw" can no longer reproduce the domain
   events it just deleted — older history would be silently destroyed.
   This directly violates the CLAUDE.md Data Integrity rule ("never replace
   a database without first verifying the target has all the source's
   data").

At the time of this decision, the compressed backup is ~200 MB, so storage
pressure is mild. This ADR therefore commits to the *direction and the
safety invariant* without enabling any deletion.

## Decision Outcome

Chosen option: **make raw retention a bounded, opt-in, coverage-guarded
capability — and ship the safety invariant now, with deletion disabled.**

Three parts, none of which removes any data:

1. **Coverage guard (the seatbelt).** Before any operation deletes the
   domain event log to rebuild it from raw, it verifies that raw still
   covers every domain event it is about to delete. Coverage = every
   domain event with a non-nil `mtga_source_id` still has its source raw
   row present. If a gap exists, the operation **raises with a clear
   message** rather than proceeding. A `force: true` option overrides for
   the genuinely-nuclear cases (`reset_raw!/0`, which intentionally
   destroys and re-reads raw from `Player.log`).

   With raw complete (the state at this decision), the guard is a verified
   no-op — there are zero orphaned domain events, so it never fires. Its
   value is permanent: the bomb can never go off by accident.

2. **Retention dial, wired to "keep everything."** A
   `raw_event_retention_days` config key is introduced, defaulting to
   `nil` (keep forever). The pruning *math* is implemented and tested
   (`Scry2.Events.RawRetention.prune_cutoff/2`), but **nothing calls a
   delete**. The dial exists and is provably off.

3. **This record.** Captures the layering so it is not relitigated: raw is
   a regenerable hedge with a bounded useful horizon; domain events are the
   precious derived truth; pruning is opt-in and may never outrun the
   coverage guard.

### Why ship the guard now, while raw is complete

The ideal moment to prove the retranslation path is safe-by-design is while
raw still covers all domain events — because the guard can be verified as a
true no-op against the full dataset before any gap exists to trip over.
Doing the safety work later, after a gap appears, means proving it correct
with the safety net already removed. Now is strictly better.

### What is explicitly deferred

- Actual pruning execution (a worker that deletes raw past the cutoff).
- Separating raw into its own SQLite file / excluding it from backups.
- Compressing `raw_json` at rest (measured ~49× with zstd).
- The "surgical" retranslate that rebuilds only the still-covered window
  instead of refusing. This is the right thing to build *the day deletion
  is enabled*, against concrete retention rules — not speculatively now.

## Consequences

**Good:**
- The data-loss bomb in all four destructive operations is defused
  permanently, verified against the full dataset.
- The architectural direction (bounded, prunable raw) is recorded and the
  knob exists, so enabling it later is a small, well-scoped change.
- Zero data removed; backups, projections, and retranslation behave
  exactly as before.

**Bad:**
- A small amount of now-inert code (the retention dial and prune math) ships
  ahead of its first real use.
- The coverage guard adds one `NOT EXISTS` count query to the start of each
  destructive operation (negligible — these are rare, manual operations).

## Related Decisions

- ADR-015: Raw event replay — establishes raw as the replay source. This
  ADR bounds how long that source must live and guards the rebuild path.
- ADR-016: Idempotent log ingestion — reprocessing yields identical state;
  the coverage guard ensures "reprocessing" can never mean "reprocessing a
  subset and discarding the rest."
- ADR-017: Event sourcing core — domain events are the source of truth for
  projections; this ADR affirms they, not raw, are the precious layer.
