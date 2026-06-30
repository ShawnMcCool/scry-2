---
status: accepted
date: 2026-06-30
---
# 042. Raw store reduction before the client/server split

## Status

Accepted — extends ADR-039 from *direction* to *execution*. The three design
questions are resolved (2026-06-30): **prune at 90 days** (stage 1b ships),
**keep stub + null the blob** for ignored types (stage 2a revises ADR-020),
**defer the domain-event diet** (stage 3). Living tracker:
`docs/storage-split-campaign.md`.

## Context and Problem Statement

A future direction is to split Scry2 into a thin capture **client** (the
only machine that can read `Player.log` — watches, parses, ships "stats")
and a **server** holding the UI, projections, and analytics for multiple
devices. A storage analysis (2026-06-30, against the real 4.03 GB DB)
established that the split's hardest decision is *where the irreplaceable
raw event log lives*, because raw (`mtga_logs_events`) is ~80% of all
per-user bytes — 3.24 GB of the 4.03 GB DB.

That analysis also produced findings that make the raw store far smaller
than its current size implies:

1. **Raw compresses well, but the redundancy is across messages.** A
   *concatenated* corpus of `GreToClientEvent` payloads compresses ~51×
   (zstd-19), but real storage compresses each `raw_json` row independently:
   measured **7.7× plain** per-row, or **~21× with a sample-dictionary** that
   recovers the cross-message redundancy. So the 3.24 GB raw store →
   **~440 MB plain or ~180 MB dictionary** (not the ~65 MB the corpus number
   implied). Game-state messages each resend most of the board.

2. **~411 MB of raw is dead weight.** `DeckGetAllPreconDecksV3` (199 MB),
   `ClientToGreuimessage` (99 MB), `GetFormats` (97 MB), and
   `DeckGetDeckSummariesV3` (16 MB) are all classified `@ignored` in
   `IdentifyDomainEvents`. Ignored types produce no domain events, ever, so
   nothing can retranslate from them — yet ADR-020 persists their full
   `raw_json` forever.

3. **`StartHook` (330 MB) is the full inventory re-dumped on every login.**
   Most logins change nothing; the blob is near-duplicated each time.

4. **`collection_snapshots` (48 MB) stores full `cards_json` per snapshot**
   even though 364 diffs already exist between the 366 snapshots
   (`collection_diffs`). Any snapshot is reconstructable from a keyframe +
   diff chain.

ADR-039 already settled the *layering* (projections rebuild from
`domain_events` alone; raw is a bounded, regenerable retranslation hedge)
and shipped the safety machinery (coverage guard + prune math + retention
dial), all wired off. It explicitly deferred: prune execution, raw
compression at rest, and the surgical retranslate.

## Decision Drivers

- **Reduce before split.** Shrinking raw to ~180–440 MB (then 90-day-bounded)
  makes "where does raw live" trivial (client keeps it locally, forever, for
  free). Don't design the split around a problem we can delete first.
- **Provable in the monolith.** Compression/dedup/retention correctness is
  verifiable against the real DB with the coverage guard in place — far
  harder across a future network boundary.
- **Don't migrate dead weight** across a new client/server protocol.
- **Data integrity is non-negotiable** (CLAUDE.md): every step is no-loss or
  loss-only-of-provably-regenerable bytes, backed by the ADR-039 guard and a
  pre-migration backup.

## Decision Outcome

Adopt a staged reduction campaign, executed in dependency order
**1a → {2a, 2b, 2c} → 1b**, before any Phase 2 split work. The living
tracker is `docs/storage-split-campaign.md`.

### Stage 1a — Compress `raw_json` at rest (keystone)
zstd the `raw_json` column; decompress transparently on the ingest /
retranslate read paths. ~3.24 GB → ~440 MB (plain) or ~180 MB (dictionary),
zero semantic change, no data loss. This is the highest-impact, lowest-risk
change and it subsumes most of stage 2a's on-disk benefit. Uses the `ezstd`
NIF (already in the dep tree via `req`). Encoding: zstd frame stored as BLOB
in `raw_json`, legacy plaintext detected by zstd magic bytes on read. TDD
with real-payload round-trip verification before migrating the real DB
(backup first). **Open: plain vs sample-dictionary — see Decision Drivers.**

### Stage 2a — Stop persisting `raw_json` for `@ignored` types
**Resolved:** keep a metadata row stub (event_type, timestamp) for the
unrecognized-type warning accounting and null the blob. This **revises
ADR-020's invariant** that ignored events keep full `raw_json`. Note: after
1a compresses everything, the byte saving here is only ~50 MB — stage 2a's
real value is semantic (don't carry noise across the split), so it is
low-priority relative to 1a and 2c.

### Stage 2b — Deduplicate `StartHook` (and similar re-dumps)
Content-hash the inventory blob; persist/emit only on change. ~80–90% of
330 MB reclaimable. `DeckGetDeckSummariesV2` is a secondary candidate.

### Stage 2c — Shrink `collection_snapshots` (~48 MB)
Direction (Shawn): keep the *current* full collection, don't hoard old
redundant data. Two parts:
- **Done — compress `cards_json`.** zstd via the `encode_entries`/
  `decode_entries` seam pair; `Snapshot.cards_json` → `:binary`; manual
  `Collection.compress_existing_cards_json!/0` backfill. ~48 MB → ~4–5 MB,
  every full collection still trivially readable, zero reconstruction risk.
- **Deferred (needs go-ahead) — drop old fulls.** Keep only the latest full
  + the diff chain (~4 MB → <1 MB) via a verify-before-null backfill
  (reconstruct each old snapshot from latest + reverse-diffs, assert equal,
  then null; keep a full at the one diff-chain gap) and ongoing nulling in
  `save_snapshot`. Touches captured source data, so gated on confirmation.

### Stage 1b — Enable bounded retention (execution)
Build the deferred ADR-039 pieces: a prune worker and the *surgical*
retranslate (rebuild only the still-covered window instead of refusing). The
coverage guard already prevents deletion of unreproducible domain events.
**Resolved:** prune at 90 days (`raw_event_retention_days = 90`).

### Stage 3 — (deferred) domain-event diet
`priority_assigned` (65 MB, 58% of domain events) and the other granular
in-game events are consumed by no current projection (held for the future
coach). **Resolved:** deferred — keep all granular domain events. Revisit
only if domain events become a real constraint.

### Target end state
Total DB ~4.0 GB → ~0.56 GB (dict) – ~0.82 GB (plain): raw ~180–440 MB,
collection ~3 MB, domain events unchanged at 211 MB, plus the shared ~165 MB
Scryfall reference.

## Consequences

**Good:**
- The Phase 2 split's dominant decision (raw location) becomes trivial.
- ~88% DB size reduction with no loss of derivable data.
- The ADR-039 retention capability finally gets its first real use, safely.

**Bad / costs:**
- Stage 2a revises ADR-020; ignored-event payloads stop being inspectable
  after the fact (mitigated by keeping the metadata stub).
- Compression adds a decode step on the ingest/retranslate read paths
  (negligible; these are not hot loops).
- Some now-inert ADR-039 code finally activates, needing the surgical
  retranslate to be correct before stage 1b ships.

## Related Decisions

- ADR-039: Raw event retention — this ADR executes its deferred parts.
- ADR-015: Raw event replay — the capability compression/retention preserve.
- ADR-020: Unrecognized events — stage 2a revises its persist-always rule.
- ADR-017: Event sourcing core — domain events remain the precious layer.
- ADR-034 / ADR-037: Collection reader / diffs — stage 2c builds on the diffs.
