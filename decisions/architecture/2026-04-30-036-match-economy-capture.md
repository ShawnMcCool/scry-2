---
status: accepted
date: 2026-04-30
---
# Match economy capture and reconciliation

## Context and Problem Statement

The walker reads MTGA's currency state (gold, gems, four wildcard tiers,
vault progress) end-to-end on every collection snapshot. Today those
snapshots are background captures: cron-scheduled, debounced log-activity
triggers, and the manual "Refresh" button. None of them are aligned to
match boundaries, so we cannot answer "what did this match earn me?"

We also cannot reconcile memory state against MTGA's log stream. The
log emits `InventoryChanged` / `InventoryUpdated` events that the
`Scry2.Economy` projection turns into `Transaction` rows. If the memory
delta over a match diverges from the sum of `Transaction` rows in the
same window, that gap is data — it tells us which categories of MTGA
economy state are not modeled in events (vault crystal conversion,
leftover-pip rounding, in-match cosmetic unlocks, etc.).

The user picked the full-vision scope (`plans.md` Section C3 + B
reconciliation + C economy timeline): per-match deltas displayed in the
match detail page, a recent-matches ticker, a daily-rollup timeline
chart, plus log reconciliation surfaced as informational diffs.
Mismatches are read as untracked-category signals, not parser bugs.

## Decision Outcome

Chosen option: a new bounded context `Scry2.MatchEconomy` that:

1. Triggers a synchronous `Collection.Reader.read/1` at every domain
   `MatchCreated` and `MatchCompleted`, persisting the result as a
   `Collection.Snapshot` tagged with the match id and phase
   (`"pre"` / `"post"`).
2. Projects a single-row-per-match `match_economy_summaries` row holding
   precomputed memory deltas, log deltas (aggregated from
   `Economy.Transaction` over the match window), and per-currency diffs.
3. Broadcasts `match_economy:updates` so LiveView surfaces stay live.

The capture mechanism reuses existing infrastructure
(`Collection.Reader`, `Collection.Snapshot`, `Economy.Transaction`).
No memory-reader changes are needed. The new context owns its trigger,
its projection table, its compute logic, and its public API; nothing
else in the codebase reaches into it.

### Why a new bounded context

`Scry2.Matches` stays a pure log projection — embedding economy reads
and reconciliation columns there would couple it to the memory reader
and bloat its schema with currency state that has nothing to do with
match identity. `Scry2.Economy` is currently log-only; mixing
memory-sourced data into it would muddy its source-of-truth contract,
and reconciliation's "compare two streams" shape doesn't fit its
"consume domain events, write rows" projector. `Scry2.Collection` owns
raw memory snapshots and should not also own match-aligned business
logic. A dedicated `MatchEconomy` keeps every existing context clean.

## Design

### Data model

**Extend `collection_snapshots`** with two nullable columns so any
snapshot can record its match context without a separate table:

```
mtga_match_id   :string  null: true
match_phase     :string  null: true   # "pre" | "post" | nil
```

Validation: when one is set, both are set. Indexed on
`(mtga_match_id, match_phase)`. Background snapshots (cron, log
activity, manual) leave both fields nil.

**New table `match_economy_summaries`** (one row per match):

| Column | Type | Notes |
|---|---|---|
| `mtga_match_id` | string, unique | FK-by-value to `matches_matches`; we don't enforce a DB FK because match upserts and economy summaries arrive on independent timelines |
| `started_at`, `ended_at` | utc_datetime_usec | from `MatchCreated.occurred_at` and `MatchCompleted.occurred_at` |
| `pre_snapshot_id`, `post_snapshot_id` | references(:collection_snapshots) | nullable when read failed |
| `memory_gold_delta`, `memory_gems_delta`, `memory_wildcards_{common,uncommon,rare,mythic}_delta` | integer | post − pre |
| `memory_vault_delta` | float | memory-only; no log analog |
| `log_gold_delta`, `log_gems_delta`, `log_wildcards_{common,uncommon,rare,mythic}_delta` | integer | sum of `Economy.Transaction` rows in [started_at, ended_at] |
| `diff_gold`, `diff_gems`, `diff_wildcards_*` | integer | memory − log; null when either side missing |
| `reconciliation_state` | string | `"complete" \| "log_only" \| "incomplete"` |
| `inserted_at`, `updated_at` | utc_datetime_usec | |

Pre/post raw values live on the linked `Collection.Snapshot` rows —
the summary stores deltas only (per ADR-027 precompute-in-projections).
The summary remains complete enough for every UI surface without a
join; the join is only needed for "show me the raw before/after" drill.

### Capture pipeline

`Scry2.MatchEconomy.Trigger` is a GenServer started under the
ingestion supervisor branch (only when `start_watcher: true`). It:

- Subscribes to `domain:events` on init.
- On `%MatchCreated{mtga_match_id, occurred_at}`:
  1. If `match_economy_capture_enabled` is `false`, ignore.
  2. Spawn a `Task.Supervisor` task — the GenServer mailbox stays
     unblocked while the read takes 1–2 s.
  3. Task calls `Collection.Reader.read/1` synchronously.
  4. On success: persist `%Snapshot{mtga_match_id:, match_phase:
     "pre"}`, insert `Summary{mtga_match_id, started_at,
     pre_snapshot_id, reconciliation_state: "incomplete"}`.
  5. Broadcast `match_economy:updates` with the new row.
  6. On read failure: insert `Summary{mtga_match_id, started_at,
     pre_snapshot_id: nil, reconciliation_state: "incomplete"}` so the
     match boundary is recorded even without memory data.
- On `%MatchCompleted{mtga_match_id, occurred_at}`:
  1. Spawn task.
  2. Task calls `Collection.Reader.read/1`.
  3. Persist `%Snapshot{mtga_match_id:, match_phase: "post"}` on
     success.
  4. Look up the existing summary row by `mtga_match_id`. If absent
     (app started mid-match), create one with no pre snapshot.
  5. Compute memory deltas from `post.field − pre.field` for each
     currency. Where pre or post is missing, leave deltas nil.
  6. Compute log deltas via `MatchEconomy.AggregateLog.over(started_at,
     ended_at)`:
     - **Gold / gems:** sum `Economy.Transaction.gold_delta` /
       `gems_delta` over rows with `occurred_at` in
       `[started_at, ended_at]`. (`Economy.Transaction` is produced
       from `InventoryChanged` events; it does not carry wildcard
       deltas.)
     - **Wildcards:** diff the most-recent
       `Economy.InventorySnapshot` rows on either side of the window
       (last snapshot at or before `started_at` vs last snapshot at or
       before `ended_at`). If a snapshot is missing on either side,
       leave the wildcard log deltas nil — they're not computable, and
       the diff column stays nil too. (`InventoryUpdated` events fire
       sporadically — typically on login or store interactions — so
       the snapshots may not bracket every match.)
  7. Compute diffs (`memory − log`) for each currency where both sides
     are non-nil.
  8. Set `reconciliation_state` per the table below.
  9. Upsert summary, broadcast `match_economy:updates`.

| pre snapshot | post snapshot | window | state |
|---|---|---|---|
| ✓ | ✓ | ✓ | `complete` |
| missing | any | ✓ | `log_only` (memory deltas nil; log deltas computed) |
| any | missing | ✓ | `log_only` (memory deltas nil; log deltas computed) |
| any | any | missing | `incomplete` (no MatchCreated seen → started_at unknown → can't bound the log window) |

"Window" means both `started_at` and `ended_at` are set. The log
aggregation range is `[started_at, ended_at]`. Memory deltas require
*both* pre and post snapshots; if either is missing we can't compute
post − pre, so the state collapses to `log_only` whenever the window
is known. The audit trail is preserved either way: any captured
snapshot is referenced by `pre_snapshot_id` / `post_snapshot_id` even
when we can't compute the corresponding delta.

`log_gold_delta` / `log_gems_delta` are **0**, not nil, when the
window is bounded but contained no `InventoryChanged` rows — zero is
a real fact. They are **nil** only when the window itself is unbounded
(orphan summary). `log_wildcards_*_delta` are nil whenever there is no
`InventorySnapshot` on either side of the window (since wildcards are
read from snapshot diffs, not transaction sums); when both snapshots
exist they're an integer (possibly 0). `memory_*_delta` is nil
whenever pre or post is missing.

**Why synchronous Task, not Oban:** match transitions need timing
accuracy at the second-or-better level. An Oban job runs whenever the
queue gets to it (could be 30+ s). A `Task.Supervisor` task starts
immediately, with crash isolation from the parent GenServer.

### Reconciliation interpretation

A non-zero `diff_*` means memory and log disagree about how much of a
currency the match changed. Per the user-confirmed semantic
("information signal, not bug signal"), the UI surfaces these
informationally — e.g. "Memory: +250 g / Log accounted for +200 g
(+50 g unaccounted)" — without alarming styling. Mismatches are read
as evidence of MTGA economy categories not yet modeled in events.

We do **not** retroactively recompute reconciliation when log events
arrive late. The design assumes `Economy.Transaction.occurred_at` is
correct (parser stamps it from the wire `timestamp`). If late-arriving
log events turn out to materially shift reconciliation in practice,
add a post-match grace window in a follow-up.

### PubSub topic

New helper in `Scry2.Topics`:

```elixir
def match_economy_updates, do: "match_economy:updates"
```

`Trigger` broadcasts `{:match_economy_updated, %Summary{}}` after every
insert / upsert. LiveView surfaces subscribe to it.

### UI surfaces — three independently-shippable layers

| Layer | Surface | Source |
|---|---|---|
| A | Match detail card on `/matches/:id` | `MatchEconomy.get_summary(match_id)` |
| B | Recent-matches ticker on the matches dashboard | `MatchEconomy.recent_summaries(limit: 10)` |
| C | `/match-economy` timeline page (daily-rollup chart + paginated table) | `MatchEconomy.timeline(opts)` |

Layer A renders three states:
- `complete` with diff = 0: "Memory: +250 g / Log: +250 g" (matched)
- `complete` with diff ≠ 0: "Memory: +250 g / Log: +200 g (+50 g unaccounted)" — soft-amber chip on the unaccounted figure
- partial states show the available side and `—` for the missing side

Layer C aggregates summaries into daily buckets: per day, sum
`memory_*_delta` over all matches with `ended_at` in that day. Bottom
of the page is a paginated table — date, opponent, format, deltas,
diffs, reconciliation state — with date-range filter.

### Settings + kill switch

New `Settings.Entry` key: `match_economy_capture_enabled`, default
`true`. Surfaced in:

- Settings → Memory Reading (alongside the existing `live_match_polling_enabled` toggle)
- Setup tour `:memory_reading` step (extend the existing single toggle into two)

When disabled, `Trigger` returns early on every domain event — no reads,
no snapshots, no summary rows.

### File layout

```
lib/scry_2/match_economy.ex                       # facade (public API)
lib/scry_2/match_economy/summary.ex               # Ecto schema
lib/scry_2/match_economy/trigger.ex               # GenServer
lib/scry_2/match_economy/compute.ex               # pure delta/diff/state functions
lib/scry_2/match_economy/aggregate_log.ex         # query Economy.Transaction window
lib/scry_2_web/live/match_economy_live.ex         # /match-economy timeline page
lib/scry_2_web/components/match_economy_card.ex   # match-detail card
lib/scry_2_web/components/match_economy_ticker.ex # dashboard ticker
priv/repo/migrations/<ts>_add_match_tag_to_collection_snapshots.exs
priv/repo/migrations/<ts>_create_match_economy_summaries.exs
test/scry_2/match_economy/...
```

### Test strategy

Following ADR-009 (no GenServer message-protocol tests) and the
project's pure-vs-resource split:

- **Pure (`async: true`, factory):**
  - `Compute.memory_deltas/2` — pre+post Snapshot → deltas
  - `Compute.diffs/2` — memory deltas + log deltas → diffs (handles nils)
  - `Compute.reconciliation_state/3` — pre/post/log presence → state
  - `AggregateLog.over/3` (logic) — Transaction list + window → log deltas (the actual query function gets resource-tested)
- **Resource (`DataCase`):**
  - `Summary` schema validation, unique-index enforcement, FK-on-delete
    behavior on `Collection.Snapshot`
  - `MatchEconomy.upsert_summary!/1` end-to-end
  - `AggregateLog.over/3` against real `Economy.Transaction` rows
- **Integration (`Trigger`):** with `Scry2.MtgaMemory.TestBackend`
  configured to a fixture, send synthesized `MatchCreated` then
  `MatchCompleted` to the GenServer (via `Topics.broadcast` to
  `domain:events`). Drain with `:sys.get_state/1`. Assert that the
  expected summary row is in the DB and that a broadcast was received.
- **Settings flag:** with the flag off, the Trigger does not insert a
  summary row.
- **No HTML assertions** — LiveView mount tests validate data flow,
  not markup.

### Failure modes

| Failure | Behavior |
|---|---|
| Reader fails on pre | `pre_snapshot_id: nil`; `memory_*_delta` stays nil; final state `log_only` once post fires |
| Reader fails on post | `post_snapshot_id: nil`; `memory_*_delta` stays nil; state `log_only` |
| MTGA crashed mid-match (no MatchCompleted) | Orphan summary stays with state `incomplete`. Real fact, kept. |
| App restart between Created and Completed | GenServer in-memory state lost; `pre_snapshot_id` is in DB. Next `MatchCompleted` looks up the summary by `mtga_match_id` and continues. |
| App started mid-match | `MatchCompleted` creates summary with no pre, state `log_only`. |
| Late log events | Not retroactively reconciled (see "Reconciliation interpretation" above). |
| Two matches in fast succession | Each has its own `mtga_match_id`; reads are independent. The Task.Supervisor handles two concurrent reads if needed (the NIF takes a lock at the OS level — the second read just queues briefly). |

### Implementation order

1. Migrations (`add_match_tag_to_collection_snapshots`,
   `create_match_economy_summaries`) + schema modules + factory helpers
2. `Compute` pure functions + tests
3. `AggregateLog` + tests against real `Economy.Transaction` data
4. `Summary` upsert + facade + tests
5. `Trigger` GenServer with `Scry2.MtgaMemory.TestBackend` integration
   test; wire into ingestion supervisor branch
6. Settings flag + Settings UI toggle + Setup tour wiring
7. Layer A: match-detail card component + integration into matches LiveView
8. Layer B: dashboard ticker
9. Layer C: `/match-economy` timeline page (chart + table + filters)

Each step ends with `mix precommit` clean. Layers A/B/C are
independently shippable — partial deployment is acceptable.

## Consequences

* Good, because the user finally sees "this match earned you X" tied
  to specific matches, with both memory and log perspectives visible.
* Good, because reconciliation diffs surface untracked categories of
  MTGA economy state without flagging them as parser bugs — the
  feature both ships value and is a discovery tool for future
  domain-event modeling.
* Good, because all four existing contexts (`Collection`, `Matches`,
  `Economy`, `Decks`) stay clean — the cross-cutting work lives in a
  dedicated bounded context that owns its trigger, projection, and
  public API.
* Good, because the implementation reuses the walker and
  `Collection.Reader` end-to-end; no new memory-reader code, no new
  walker offsets.
* Good, because the kill switch composes with the existing memory-
  reading toggle, so the user has one place to disable the whole
  memory-reader subsystem if anything goes wrong.
* Bad, because we add a new bounded context, which means more module
  surface and another supervisor child to maintain.
* Bad, because synchronous Task-based reads put 1–2 s of memory-read
  work on the critical path of `MatchCreated` / `MatchCompleted`.
  Acceptable: the Task is detached from the Trigger GenServer mailbox,
  so it does not block other domain events.
* Bad, because reconciliation state may stay `incomplete` for matches
  where the reader failed — surfacing a partial story per match.
  Acceptable per the user-confirmed informational semantic.

## Related

- ADR-027 (precompute in projections) — projection stores deltas, not raw
- ADR-009 (GenServer API encapsulation) — Trigger tested through public API
- ADR-034 (memory-read collection) — `Collection.Reader` used as-is
- `plans.md` Sections B (reconciliation), C (pre/post-match capture), C-aggregation timeline
