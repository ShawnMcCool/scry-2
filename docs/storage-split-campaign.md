# Campaign: storage reduction → client/server split

**Status:** active · **Started:** 2026-06-30 · **Owner:** Shawn + Claude

A multi-session campaign with two phases:

1. **Reduce** the on-disk footprint of the monolith — dominated by the raw
   event log — to the point where storage is no longer a constraint on
   architecture.
2. **Split** the app into a thin capture **client** (watches `Player.log`,
   parses, ships "stats") and a **server** that holds the UI, projections,
   and analytics.

**The campaign is deliberately sequenced reduce-before-split.** See
[Why reduce first](#why-reduce-before-split). This file is the durable
record so the work can continue across sessions; update the
[status table](#stage-status) and [session log](#session-log) as it moves.

---

## North star

The split's single hardest decision is *where the irreplaceable raw event
log lives*, because raw is ~80% of all per-user bytes. If raw stays at
~3.2 GB, the split is fraught (client carries GBs, or the server does). If
raw is reduced to ~180–440 MB and 90-day-bounded, the decision evaporates: the client keeps a
small compressed, retention-bounded raw log locally forever at negligible
cost, and "what crosses the wire" reduces to domain events. **Phase 1
deletes the problem that makes Phase 2 hard.**

---

## Measured baseline (2026-06-30, real DB)

Real production DB: `~/.local/share/scry_2/scry_2.db`, **4.03 GB**
(983,901 pages × 4096 B). Span: 2026-04-06 → 2026-06-30 (~85 days).
608 matches, 964 games, 27 drafts, 300 decks, 365 collection snapshots.

### Storage by tier

| Tier | Table(s) | On-disk | % | Per row |
|---|---|---|---|---|
| Raw event log | `mtga_logs_events` (+idx ~330 MB) | **3.24 GB** | 80% | 4,602 B |
| Domain events | `domain_events` (+idx ~150 MB) | 211 MB | 5% | 371 B |
| Reference (shared, not per-user) | `cards_scryfall` + `cards_cards` + `cards_mtga` | ~165 MB | 4% | — |
| Collection snapshots | `collection_snapshots` | 48 MB | 1% | 131 KB |
| Projections | all `*_` projection tables | <20 MB | <1% | tiny |

### Raw log composition (the 3.24 GB)

| Event type | Bytes | avg/row | Class | Produces domain events? |
|---|---|---|---|---|
| `GreToClientEvent` | 2.0 GB | 5.5 KB | handled | yes — the real gameplay telemetry |
| `StartHook` | 330 MB | 202 KB | handled | yes — **full inventory re-dumped every login** |
| `DeckGetAllPreconDecksV3` | 199 MB | 506 KB | **ignored** | **no — static precon catalogue (dead weight)** |
| `ClientToGreuimessage` | 99 MB | 412 B | **ignored** | **no — UI animation (dead weight)** |
| `GetFormats` | 97 MB | 229 KB | **ignored** | **no — static format catalogue (dead weight)** |
| `ClientToGremessage` | 55 MB | 878 B | handled | yes — game actions |
| `EventGetCoursesV2` | 28 MB | 7 KB | handled | yes |
| `DeckGetDeckSummariesV2` | 20 MB | 700 KB | handled | yes — deck list re-dumps |
| `DeckGetDeckSummariesV3` | 16 MB | 36 KB | **ignored** | **no — static (dead weight)** |
| `GraphGetGraphState` | 15 MB | 2.4 KB | handled | yes |

**~411 MB of `raw_json` is stored for `@ignored` event types** — events
that produce no domain events, ever, so nothing can ever retranslate from
them. Pure dead weight (ADR-020 persists `raw_json` even for ignored types).

### Compression (decisive — corrected 2026-06-30)

**The redundancy is ACROSS messages, not within one.** Each `GreToClientEvent`
resends most of the board, so a *concatenated* corpus compresses ~51× (zstd-19)
— but real storage compresses each `raw_json` row **independently**, which
loses that cross-message redundancy.

Measured per-row on 4,000 real `GreToClientEvent` payloads (avg 4.7 KB):

| Approach | Ratio | Notes |
|---|---|---|
| plain zstd L3 | 6.9× | fast; level barely matters per-row |
| plain zstd L19 | 7.7× | |
| sample-dictionary (256 KB–1 MB) L19 | **21–22×** | recovers cross-message redundancy; round-trip verified |

**Measured full-store (2026-06-30):** a 23,322-row uniform sample across the
*whole* table (all event types, read-only) compresses **8.35× blended** at
L19 — static dumps compress harder than GRE, so the blend beats GRE-alone.
**Raw store 3.24 GB → ~388 MB.** Note: SQLite does not shrink the file on
UPDATE; a `VACUUM` after the backfill is required to reclaim disk.

So the realistic raw-store target is **~388 MB plain** (measured) or ~180 MB
with a dictionary — both huge vs 3.24 GB, neither the earlier (wrong) ~65 MB.
**Plain-vs-dictionary is an open design question (see below).** ezstd has no
trainer; the "dictionary" is a held-out sample of real payloads fed as raw
dictionary content (`create_cdict`/`create_ddict`), versioned by zstd's
frame dict-id.

### Domain event composition (211 MB)

`priority_assigned` is **329,081 rows / 65 MB / 58% of all domain events**.
Cross-referenced against projection handlers: the granular in-game events
(`priority_assigned`, `priority_passed`, `phase_changed`, `spell_cast`,
`spell_resolved`, `combat_damage_dealt`, `turn_started`, `land_played`,
`zone_changed`, `targets_declared`, `counter_added`, `attackers_declared`,
`blockers_declared`, `permanent_destroyed`, `token_created`,
`life_total_changed`, `permanent_stats_changed`, `card_exiled`) are
**consumed by no current projection**. They exist per the "maximal detail
extraction" rule, held for the future pattern-detection coach. `card_drawn`
and `mulligan_offered` ARE consumed (decks projections).

---

## Storage cost model

Three independent drivers — not pure per-game. Measured coefficients:

```
Raw_uncompressed  ≈  2.26 MB·games  +  ~0.6 MB·sessions  +  ~1.8 MB·active_days
Domain_events     ≈  0.22 MB·games  (589 events/game, 371 B each)
Projections       ≈  ~1.6 KB·match  (disposable, rebuildable from domain events)
Collection        ≈  131 KB·day     (one snapshot/day — diffable to ~1 KB/day)
Reference         =  ~165 MB FIXED   (shared; amortizes to ~0 per incremental user)

Raw_zstd     ≈ Raw / ~8 (plain)  or  / ~21 (dictionary)
Domain_zstd  ≈ Domain / ~10
```

Per game: **~2.3 MB raw → ~290 KB plain / ~110 KB dict** (capture side) vs
**~0.22 MB stats / ~22 KB** (analytics side). At the user's rate (~11
games/day): ~13.9 GB/yr raw uncompressed → ~1.7 GB/yr plain / ~660 MB/yr dict.

---

## Prior art already in the codebase

**Phase 1 stage 1 is architecturally settled by ADR-039** ("Raw event
retention — bounded, prunable, never a silent data-loss path", 2026-05-30).
It already shipped, wired OFF:

- `Scry2.Events.RawRetention.coverage_verdict/1` — seatbelt: refuses to
  delete domain events that surviving raw can't reproduce.
- `Scry2.Events.RawRetention.prune_cutoff/2` — prune-boundary math, tested.
- `raw_event_retention_days` config key, default `nil` (keep forever);
  `defaults/scry_2.toml:49` suggests `90`.
- `Scry2.Events.raw_coverage_gap/0`, `retranslate_from_raw!/1` (with
  `force:` override), `replay_projections!/0`.

ADR-039 **deferred**: actual prune execution, raw-in-separate-file,
`raw_json` compression at rest, and the "surgical" retranslate that rebuilds
only the still-covered window instead of refusing.

The collection diff primitive **already exists**: 364 diffs between 366
snapshots (`collection_diffs`: `cards_added_json`/`cards_removed_json`), yet
every snapshot still stores full `cards_json`.

---

## The plan

### Phase 1 — Reduce

#### Stage 1a — Compress `raw_json` at rest  ⟵ KEYSTONE
Lowest risk, highest impact. zstd the `raw_json` column. 3.24 GB → ~440 MB
(plain) or ~180 MB (dictionary), zero semantic change, no data loss.
Subsumes most of 2a's benefit.

**Dependency:** `ezstd` (`~> 1.0`) — already in the tree as an optional dep
of `req`, so adding it to `mix.exs` resolves cleanly. Chosen over extending
the Rust crate (simpler, battle-tested).

**Encoding decision:** store the zstd frame as a BLOB in `raw_json`. SQLite
keeps BLOB storage class even in a TEXT-affinity column, and the parser keeps
producing plaintext JSON — compression happens only at the persist boundary.
On read, detect legacy plaintext vs zstd by the **zstd magic bytes**
(`0x28 B5 2F FD`); absent → return as-is. This makes every read path tolerant
of a mixed (legacy + compressed) table during and after migration. No second
column (respects no-deprecated-columns).

**Implementation surface (mapped 2026-06-30):**
- Codec: new `Scry2.Events.RawCompression` (pure) — `compress/1`,
  `decompress/1` (magic-byte legacy passthrough). TDD against real payloads.
- Schema: `lib/scry_2/mtga_log_ingestion/event_record.ex:20` —
  `field :raw_json, :string` → `:binary`; changeset cast unchanged.
- Write boundary: compress at persist. Sites that build/insert rows:
  `watcher.ex:290`, the `event_record` changeset path. **Parser stays
  plaintext** (`extract_events_from_log.ex` Event structs).
- Read boundary: decompress on load.
  - `lib/scry_2/events/raw_payload.ex:29,43` `decode/1` — the main seam
    (process-cached `Jason.decode`); pipe through `RawCompression.decompress/1`.
  - `lib/scry_2/mtga_log_ingestion.ex:402` second `Jason.decode(record.raw_json)`.
- **Gotcha — SQL filter:** `mtga_log_ingestion.ex:243`
  `where: r.raw_json != "{}"` breaks on compressed binary. Fix: compare
  against the precomputed compressed form of `"{}"`, or move the empty-payload
  filter into application code, or add a tiny `empty_payload` flag column.
- Migration: batched in-place compress of existing ~705k rows. **Heavy +
  irreplaceable data — back up the real 4 GB DB and run with Shawn present;
  do NOT auto-apply.** Verify round-trip on a sample before the full pass.
- Tests: codec round-trip (real fixtures), mixed-table read (legacy +
  compressed rows both decode), changeset accepts compressed binary,
  retranslate/coverage still work post-compression.

#### Stage 2a — Stop persisting `raw_json` for `@ignored` types
~411 MB raw, but **~50 MB after 1a compresses it** (less with a dict) — so post-1a this is a
*semantic* cleanup (don't carry noise across the split, don't spend compress
CPU on garbage), not a byte win. Keep a row stub (event_type, timestamp) for
the unrecognized-type warning accounting; null the blob. **Changes the
ADR-020 invariant** → needs sign-off. Likely optional once 1a ships.

#### Stage 2b — Deduplicate `StartHook`
~330 MB raw → **~40 MB after 1a** (repetitive inventory JSON compresses well;
better with a dict). Post-1a, dedup still buys something but is lower
priority; treat as optional. Was a big win pre-compression.

#### Stage 2c — Collapse `collection_snapshots` to keyframe + diff
48 MB → ~3 MB. Drop `cards_json` from non-keyframe rows; reconstruct from
nearest keyframe forward through the existing diff chain.

#### Stage 1b — Enable bounded retention (execution)
Build the deferred ADR-039 pieces: prune worker + surgical retranslate
(rebuild only the still-covered window). Coverage guard already prevents
unreproducible loss. Needs a retention-window decision.

#### Stage 3 — (optional, deferred) domain-event diet
Stop emitting unconsumed granular events (`priority_assigned` = 65 MB the
standout). Fights maximal-detail philosophy + future coach; only ~100 MB
even if fully gutted. Requires explicit user confirmation per ignore-means-noise.

### Target end state

| | Now | After Phase 1 |
|---|---|---|
| Raw store | 3.24 GB | ~180 MB (dict) – ~440 MB (plain), then 90-day-bounded |
| Collection snapshots | 48 MB | ~3 MB |
| Domain events | 211 MB | 211 MB (stage 3 deferred) |
| **Total DB** | **~4.0 GB** | **~0.56 GB (dict) – ~0.82 GB (plain)** |

### Phase 2 — Split (designed, not started)

Recommended **Design B** from the 2026-06-30 analysis: client = capture +
system-of-record for (now-tiny) raw; server = domain events + projections +
UI, serving multiple devices. Client ships domain events ("stats") up;
server can request raw replay on the rare re-derivation. Per-user server
cost ~90 MB + 165 MB shared reference, +~7 MB/user/month compressed.
Rejected: Design A (client discards raw — breaks fix-translation/reingest);
Design C (replicate full raw up — per-user GB unless compressed).

### Why reduce before split
1. Shrinking raw to ~180–440 MB (then 90-day-bounded) makes "where does raw live" trivial — the client
   just keeps it. Don't design the split around a deletable problem.
2. Correctness of compression/dedup/retention is provable in the monolith
   against the real DB with the coverage guard in place — far harder across
   a network boundary.
3. Don't migrate dead weight (411 MB ignored + 45 MB redundant snapshots)
   across a new protocol.

Dependency chain: **1a → 2a/2b/2c → 1b → Phase 2.**

---

## Design questions — RESOLVED (2026-06-30)

1. **Retention policy → PRUNE AT 90 DAYS.** Build stage 1b (prune worker +
   surgical retranslate). `raw_event_retention_days = 90`.
2. **Ignored `raw_json` (stage 2a) → KEEP STUB, NULL THE BLOB.** Keep each
   ignored event's row (event_type + timestamp) for unrecognized-type
   accounting; stop storing its `raw_json`. **Revises ADR-020's
   persist-always invariant** — capture that in the ADR-020 update.
3. **Stage 3 domain-event diet → DEFERRED.** Keep all granular domain events
   (incl. `priority_assigned`) for the future coach. Revisit only if domain
   events become a constraint.

Implementation-level (Claude decides, non-blocking): compression lib
(`ezstd` chosen — simplest, battle-tested), keyframe interval for 2c.

4. **Stage 1a plain vs dictionary → PLAIN per-row zstd.** Measured 8.35×
   blended → raw store ~388 MB (90-day-bounded). Rejected the dictionary:
   ~200 MB leaner but a single point of failure (lose it → whole raw store
   undecodable), against the data-integrity ethos. Self-contained frames.

### Decisions RESOLVED 2026-07-01 + findings

- **Q5 → skip stage 2a** ("ignore for now"). ~50 MB post-compression; not worth
  the ingestion/ACL boundary change.
- **Q6b → approved, but not built (recommend skip).** After compression the
  collection table is ~4 MB. Dropping old fulls to reach <1 MB requires: (a) a
  SQLite **table-rebuild migration** (`cards_json` is `NOT NULL`), and (b) a
  reconstruction+verify pass (rebuild each old snapshot from latest + reverse
  diffs `prev = next − acquired + removed`, assert == stored, then drop; keep a
  full at the one diff-chain gap). That's disproportionate machinery + a
  migration touching irreplaceable captured collection data for ~3 MB.
  **Recommendation: treat compression as sufficient.** If we still want it,
  do it together (backup first). The reverse-diff reconstruction algorithm and
  gap handling are specified in the session log below.
- **Q7 → approved ("i guess"), NOT built unattended.** The 90-day prune
  **deletes the irreplaceable raw event log** and requires reworking the core
  destructive retranslate path (`Events.retranslate_from_raw!` currently
  `ensure_raw_coverage!` → `delete_all(EventRecord)` → rebuild; it *refuses* on
  a coverage gap). "Surgical retranslate" = rebuild only the still-raw-covered
  window and KEEP domain events older than the prune horizon instead of
  refusing. Plan below. This is the one remaining meaningful win (bounds
  long-term raw growth) but it is destructive — **build together, with a backup
  and firm intent, not overnight on "i guess."**

### Stage 1b — BUILT (2026-07-01, manual gated, no cron)

Code-complete and tested; **not yet run on the real DB** (it deletes the
irreplaceable raw log, so the operator runs it deliberately, after a backup).

- `Scry2.MtgaLogIngestion.prune_before!(cutoff)` — deletes raw
  `mtga_logs_events` older than `cutoff` (exclusive); returns the count. Never
  touches `domain_events`. Table-owner mechanic.
- `Scry2.Events.prune_raw!(opts)` — orchestration. Reads
  `raw_event_retention_days` from config (override `:retention_days`; `:now`
  for a fixed clock). `nil` days → no-op `%{deleted: 0, cutoff: nil}`. Else
  deletes raw older than `now - days`, returns `%{deleted:, cutoff:}`. Config
  defaults to `nil` (keep forever), so an accidental call is a no-op until
  `raw_event_retention_days = 90` is set or passed.
- `Scry2.Events.retranslate_covered!/0` — the post-prune-safe retranslate.
  Deletes + rebuilds ONLY domain events whose raw source still exists (the
  covered window); **preserves** orphaned (source pruned) and synthetic
  (nil-source) events; seeds `self_user_id` from persisted `IngestionState`
  (boundary decision: seed + accept tail drift for one match straddling the
  cutoff); then `replay_projections!`. Contrast `retranslate_from_raw!/1`,
  which refuses on a gap and, when forced, wipes the whole domain log.
- `:seed_self_user_id` threaded through `IngestRawEvents.run_retranslation`.
- The full-rebuild seatbelts (`retranslate_from_raw!`, `reingest!`,
  `reset_all!`) are unchanged — they still refuse on the (now-permanent)
  post-prune coverage gap unless forced. That's correct: after a prune, a full
  wipe-and-rebuild WOULD lose the orphaned history, so it must refuse.
- Tests: `test/scry_2/events/raw_prune_test.exs` +
  `surgical_retranslate_test.exs` (11 tests). Full precommit 2649 green.

**Operational runbook (run deliberately, attended):**
1. Back up the real DB (`~/.local/share/scry_2/scry_2.db`).
2. In the remote shell: `Scry2.Events.prune_raw!(retention_days: 90)` →
   inspect `%{deleted:, cutoff:}`. `VACUUM` to reclaim disk (SQLite won't
   shrink the file on DELETE).
3. If the translator later changes, rebuild the still-covered window with
   `Scry2.Events.retranslate_covered!()` (NOT `retranslate_from_raw!`, which
   would refuse on the post-prune gap or lose orphaned history when forced).

**Deferred:** the Oban cron that prunes on a schedule — only after the manual
path is proven on the real DB and Shawn opts in.

### Stage 1b plan (surgical retranslate + prune) — original design notes

1. **Surgical retranslate.** New path that, given the coverage gap, deletes and
   rebuilds ONLY domain events whose `mtga_source_id` still has surviving raw
   (the covered window), leaving older domain events untouched. Contrast with
   `retranslate_from_raw!` which deletes ALL domain events then rebuilds.
   Add as a distinct function; keep the refusing one for full rebuilds.
2. **Prune function** (manual/gated, mirrors the backfills): delete raw older
   than `raw_event_retention_days` (90). Uses `RawRetention.prune_cutoff/2`.
   Never auto-run.
3. **Optional Oban cron** to prune on a schedule — only after the manual path is
   proven and Shawn opts in.
4. Coverage guard (ADR-039) already prevents deleting domain events that raw can
   no longer reproduce.

### (historical) open questions

5. **Stage 2a placement (stub+null ignored).** `@ignored` is domain knowledge
   in `IdentifyDomainEvents` (the ACL), but raw is persisted in
   `MtgaLogIngestion` *before* the ACL runs (ADR-015 ordering). So where does
   the null-the-blob happen? (a) ingestion reads the ACL's published
   ignored-type set at write time (boundary crossing); (b) a post-processing
   step nulls raw_json after the ACL classifies it ignored (two writes, cleaner
   boundary). Also: 2a is now only ~50 MB post-compression — confirm it's still
   worth doing vs dropping. **Recommend (b) if done at all; low priority.**
6. **Stage 2c → "need current full collection, not old redundant data."**
   DONE part 1: zstd-compress `cards_json` (option c) — 48 MB → ~4-5 MB, every
   full collection still trivially readable, zero reconstruction risk.
   **OPEN (Q6b): also DROP old fulls entirely** (keep only the latest full +
   the diff chain)? That gets ~4 MB → <1 MB but touches captured source data.
   Safe path is designed: a verify-before-null backfill (reconstruct each old
   snapshot from latest + reverse-diffs, assert == stored, THEN null; keep a
   full at the one diff-chain gap) + ongoing null-the-third-most-recent in
   `save_snapshot` (so synchronous diff + async crafts/economy consumers, which
   read consecutive pairs and already tolerate `cards_json: nil`, always have
   their fulls). Consumers verified: UI reads latest only; attribution reads
   pairs at creation. **Needs Shawn's go-ahead before nulling captured data.**
7. **Stage 1b surgical retranslate design.** 90-day prune needs retranslate to
   rebuild only the still-covered window instead of refusing (coverage guard).
   Confirm the approach before building, and the prune execution is gated like
   the backfill (deletes raw).

---

## References

- ADR-039 `decisions/architecture/2026-05-30-039-raw-event-retention.md` — direction + seatbelt
- ADR-042 (this campaign's execution ADR) — `decisions/architecture/2026-06-30-042-*.md`
- ADR-015 raw replay · ADR-017 event sourcing · ADR-020 unrecognized events · ADR-034 collection reader · ADR-037 craft attribution
- `lib/scry_2/events/raw_retention.ex` · `lib/scry_2/events.ex` (coverage/retranslate) · `lib/scry_2/events/identify_domain_events.ex` (handled/ignored sets ~line 154)
- `lib/scry_2/collection/diff.ex` · `collection_diffs` table
- skill: `events`

---

## Stage status

| Stage | Status | Notes |
|---|---|---|
| 1a compress raw at rest | ✅ DONE + backfilled (2026-07-01) | PLAIN per-row zstd wired end-to-end; backfill RUN on real DB: raw_json 2.96 GB → 379 MB (7.8×); DB 3.8 GB → 1.3 GB after VACUUM. Backfill made batch-transactional. |
| 2a stub+null ignored raw_json | ⛔ skipped | Q5: ignore for now (Shawn). ~50 MB post-compression; not worth the ACL-boundary change |
| 2b dedup StartHook | ⛔ skipped | marginal after 1a; low priority |
| 2c collection snapshots | ✅ compression DONE + backfilled (2026-07-01) | `cards_json` → :binary zstd; backfill RUN on real DB: 48.8 MB → 3.5 MB (14×). Q6b (drop old fulls) not built — needs NOT-NULL table-rebuild + reconstruction for ~3 MB; compression deemed sufficient |
| 1b retention execution (90d) | ✅ code built + tested (2026-07-01), NOT yet run on real DB | Manual gated path, no cron: `MtgaLogIngestion.prune_before!/1` + `Events.prune_raw!/1` (config-gated prune) and `Events.retranslate_covered!/0` (surgical retranslate — rebuilds only the covered window, keeps orphaned + synthetic, seeds self_user_id). 11 TDD tests, full precommit green. Run deliberately after a backup; runbook below |
| 3 domain-event diet | ⛔ deferred | Q3: keep all granular events |
| Phase 2 split | 🚧 in progress — reframed to a multi-user analytics platform | Spec: `docs/superpowers/specs/2026-07-04-client-server-split-design.md` (fat SQLite client + uplink → shared Postgres analytics store; raw stays client-side; opt-out anonymized aggregation). Phases 2a→2d. **2a shipped** (client uplink core: UploadKey + WireEvent codec + unsent-batch selection; 14 tests). Supersedes the earlier "Design B / multiple devices" framing |

## Session log

- **2026-07-04** — Phase 2 design pass (brainstorming) + Phase 2a shipped.
  **Reframed Phase 2** from the campaign's "Design B / one user, many devices"
  to a **multi-user analytics platform**: fat SQLite client (= today's app +
  uplink; standalone = self-host) → frequent small HTTPS batches of domain
  events only → shared Postgres analytics store (user attribution, not tenant
  isolation) → opt-out anonymized cross-user aggregation. Raw stays 100%
  client-side; clients own retranslation + re-upload via a content-addressed,
  retranslation-stable upload key (idempotent upsert). Accounts likely,
  provider deferred. Full spec:
  `docs/superpowers/specs/2026-07-04-client-server-split-design.md`; plan for
  2a: `docs/superpowers/plans/2026-07-04-phase-2a-client-uplink-core.md` (both
  untracked, per project convention). **Shipped Phase 2a** (subagent-driven,
  TDD, 3 commits `e735afeb`/`017f8889`/`20445e9b`): `Scry2.Uplink.UploadKey`,
  `Scry2.Uplink.WireEvent` (codec), `Scry2.Uplink` (unsent-batch over the
  reused named-cursor store). Pure client-side library, **zero runtime behavior
  change** (no production callers yet); 14 new tests, full precommit green
  (2663 tests). **Re-scope note:** the spec's "thread user_scope through
  projectors" moved from 2a → 2b — it needs server-side `user_id` columns and
  would be dead plumbing in the client. All Phase-2 commits unpushed (hold).
- **2026-07-01 (cont. 3)** — Committed Stage 1b (`d45edfaa`, not pushed).
  **Validated the prune's real-world impact read-only against the static backup
  snapshot** (zero risk, live instance untouched): 713,590 raw rows, span
  2026-04-06 → 2026-06-30 (~86 days). A **90-day prune today deletes 0 rows** —
  the DB isn't 90 days deep yet, so bounded retention correctly removes nothing
  until data ages past the window (starts biting within days, then continuously;
  for reference a 60d window would drop ~272k rows / 38%, a 30d window ~466k /
  65%). Confirms the timestamp comparison works against the real stored format
  (`2026-04-06T18:47:40Z`). **Conclusion: nothing destructive to run now**; the
  prune is a safe no-op at 90d today and only matters as data ages. Kicked off
  the **Phase 2 design pass** (see below / new ADR).
- **2026-07-01 (cont. 2)** — Built Stage 1b (manual gated, no cron), test-first.
  Boundary decision (Shawn): **seed self_user_id, accept tail drift.**
  `MtgaLogIngestion.prune_before!/1` deletes raw older than a cutoff (never
  domain events); `Events.prune_raw!/1` computes the cutoff from
  `raw_event_retention_days` (config-gated, nil = keep-forever no-op) and
  prunes. `Events.retranslate_covered!/0` is the surgical, post-prune-safe
  rebuild: deletes+rebuilds ONLY domain events whose raw source survives,
  preserves orphaned + synthetic events, seeds self_user_id from persisted
  `IngestionState`, then `replay_projections!`. Threaded `:seed_self_user_id`
  through `IngestRawEvents.run_retranslation`. 11 new TDD tests
  (raw_prune_test + surgical_retranslate_test); full precommit **2649 tests
  green, zero warnings**. **NOT run on the real DB** — destructive (deletes
  irreplaceable raw); operator runs it deliberately after a backup (runbook
  above). Oban cron deferred until the manual path is proven on the real DB.
- **2026-07-01 (cont.)** — EXECUTED the backfills on the real DB + fixed the
  live instance. **Incident:** the June-29 VM had hot-reloaded my changed
  `mtga_log_ingestion.ex` (Phoenix dev code-reloader) but never loaded the new
  `:ezstd` NIF → Watcher crashed on `:ezstd.compress/2` → max restart intensity
  → `scry_2` app down (nothing on 6015). **Lesson: adding a native dep requires
  a full restart; the dev code-reloader will pick up source mid-flight and
  crash on the missing NIF.** Fix = restart. Then: backed up DB (verified,
  4.08 GB), batch-transactioned `RawCompressionBackfill` (avoid 715k fsyncs),
  stopped instance, ran both backfills standalone (single writer):
  **raw_json 2.96 GB → 379 MB (7.8×), cards_json 48.8 MB → 3.5 MB (14×)**;
  VACUUM'd **3.8 GB → 1.3 GB DB**; restarted, healthy, all read paths (collection/
  operations/dashboard) 200, 0 plaintext raw rows remain. Backup kept at
  `~/.local/share/scry_2/scry_2.db.pre-compress-backfill-2026-07-01`.


- **2026-07-01** — Shawn: Q5 skip 2a; Q6b "seems ok"; Q7 "i guess".
  Investigated both before building. **Findings that changed the calculus:**
  Q6b needs a NOT-NULL table-rebuild migration + reconstruction/verify for only
  ~3 MB on irreplaceable captured collection data (compression already got it to
  ~4 MB); Q7 deletes the irreplaceable raw log and reworks the core destructive
  retranslate path. Per the project's data-integrity-first culture, **did NOT
  build either unattended overnight** — recorded ready-to-build plans + a
  recommendation to treat compression as sufficient for collection and to do the
  raw prune together with a backup. Skipped 2a/2b. Net: the two big safe wins
  (1a raw compression, 2c collection compression) are done; the remaining items
  are destructive/low-ROI and await a firmer, attended go.
- **2026-06-30 (cont. 4)** — Shawn directed stage 2c: "need current full
  collection, don't keep old redundant data." Implemented the safe part —
  zstd-compress `cards_json` (mirror of 1a): `Snapshot.cards_json` → `:binary`,
  compress/decompress folded into the `encode_entries`/`decode_entries` seam
  pair (transparent to all callers), `Collection.compress_existing_cards_json!/0`
  manual backfill. TDD, 2638 tests green, format clean. Mapped all cards_json
  consumers: UI reads latest only; crafts/economy/snapshot_diff read consecutive
  pairs at creation and already tolerate nil cards_json. **Stopped before the
  riskier "drop old fulls" step (Q6b) — it nulls captured source data; awaiting
  Shawn's go-ahead. Design recorded above.**
- **2026-06-30 (cont. 3)** — Measured full-store compression read-only on the
  real DB (23,322-row sample, app not booted, DB untouched): **8.35× blended →
  raw store 3.24 GB → ~388 MB.** Added VACUUM caveat to the backfill (SQLite
  won't shrink the file on UPDATE). Recorded next-stage design questions
  (Q5 2a placement, Q6 2c snapshot direction, Q7 1b surgical retranslate) —
  these gate further progress; **stopped here awaiting Shawn's decisions.**
- **2026-06-30 (cont. 2)** — Wired stage 1a end-to-end (TDD, 2634 tests green,
  format clean): schema `raw_json` → `:binary`; compress at both write seams
  (`insert_event!` + `insert_events!` via a shared idempotent
  `compress_raw_json/1` using `RawCompression.ensure_compressed/1`);
  decompress at read seams (`RawPayload.decode/1`, `format_error_for_export`);
  rewrote `deferred_types_with_payloads/1` to test emptiness in Elixir (the
  `:binary` field broke the SQL `!= "{}"` literal — BLOB/TEXT affinity); added
  `RawCompressionBackfill` (manual, resumable, idempotent — NOT a migration,
  run from the live remote shell after a DB backup). Retranslate/coverage need
  no change (they go through the read seam). **REMAINING for 1a: run the
  backfill on the real 4 GB DB — gated on backup + Shawn present.** Next stages
  ready: 2a (stub+null ignored), 2c (collection keyframe+diff), 1b (90d prune).
- **2026-06-30 (cont.)** — Resolved Q4: PLAIN per-row zstd. Built stage-1a
  codec `Scry2.Events.RawCompression` (`compress/1`, `decompress/1` with
  magic-byte legacy passthrough, `compressed?/1`) TDD, 7/7 green, clean
  compile. Added `ezstd ~> 1.0`. **Corrected the compression facts: per-row
  is 7.7× plain (NOT the 51× concatenated-corpus number) → raw store ~440 MB.**
  Next entry point: schema `event_record.ex:20` `:string`→`:binary`; wire
  `compress` at write boundary (`watcher.ex:290` + changeset) and `decompress`
  at read seams (`raw_payload.ex:29,43`, `mtga_log_ingestion.ex:402`); fix the
  `raw_json != "{}"` filter (`mtga_log_ingestion.ex:243`); then batched
  migration — **back up the 4 GB DB + Shawn present; do not auto-apply.**
- **2026-06-30** — Measured real DB; found raw = 80% / compresses ~50×;
  found 411 MB ignored dead weight + redundant StartHook + full collection
  snapshots alongside existing diffs. Discovered ADR-039 already settles
  stage-1 direction. Wrote this tracker + ADR-042. Resolved all 3 design
  questions: prune@90d / stub+null ignored / defer diet. Refined: 1a
  compression subsumes most of 2a+2b's byte savings (they become semantic
  cleanups). Next: implement stage 1a (TDD; do NOT migrate the real 4 GB DB
  without a backup + Shawn present).
