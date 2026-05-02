---
status: accepted
date: 2026-05-02
---
# Wildcard craft attribution from collection snapshots

## Context and Problem Statement

The user wants per-craft visibility on the Economy page: `[timestamp,
rarity, card name, qty]` for every wildcard spent — not just running
totals. Today the walker reads `wildcards_common/uncommon/rare/mythic`
on every snapshot, and `Scry2.Collection.SnapshotDiff` already
computes per-card `acquired`/`removed` deltas between consecutive
snapshots. Wildcard *totals* are visible in the chart on `/economy`,
but **which card was crafted with each spent wildcard is not**.

The MTGA log path is dead: `Inventory.Updated` with `wcRareDelta` /
`Craft` context fields was removed from `Player.log` around
**Aug 2021** (memory note `project_mtga_collection_not_in_log`,
matches mtga-utils issue #33). A 2026-05-02 re-verification against
the user's own 47 MB `Player.log` (144,671 lines) confirms zero hits
for `Inventory.Updated`, any `wc*Delta` field name, `aetherized`, or
`PlayerInventory.GetPlayerCardsV3`. The only remaining attribution
signal is the memory snapshot pair that brackets a craft.

ADR-034 (memory-read collection) and ADR-036 (match economy capture)
have already paid for the heavy infrastructure: the walker is in
place, snapshots persist `wildcards_*` columns, and per-card diffs
are produced and broadcast on `Topics.collection_diffs/0`. The work
this ADR scopes is the **attribution layer** that turns "this rarity
went down by 1 + this card went up by 1 in the same window" into a
durable craft record.

## Decision Outcome

Chosen option: a new bounded context `Scry2.Crafts` that:

1. Subscribes to `Topics.collection_diffs/0` PubSub.
2. For every `{:diff_saved, diff}`, fetches the two referenced
   `Collection.Snapshot` rows.
3. Runs a pure attribution function over the snapshot pair to detect
   wildcard-spend events.
4. Persists detected crafts as rows in a new `crafts` table.
5. Broadcasts on a new `Topics.crafts_updates/0` topic.
6. Renders a recent-crafts card on the existing `/economy` page.

The capture mechanism reuses the entire walker + snapshot + diff
chain unchanged. No memory-reader changes. No new walker offsets. No
new collection sampling cadence. The new context owns its
subscriber, schema, attribution logic, and public API.

### Why a new bounded context

`Scry2.Collection` owns memory snapshots and per-card diffs as raw
data; it should not also own domain interpretation of "what was
crafted." `Scry2.Economy` is currently a log-only projection
(consumes `domain:events`, writes `economy_*` rows); attribution is
sourced from memory snapshots, a different pipeline, and folding it
in would muddy Economy's source-of-truth contract. `Scry2.Matches`
is unrelated. A dedicated `Scry2.Crafts` keeps every existing
context clean, mirrors the `Scry2.MatchEconomy` precedent from
ADR-036, and lets the craft log evolve independently of either
parent.

### Why memory snapshots, not domain events

Crafts are derived facts inferred from before/after snapshot pairs,
not domain events extracted from the log. The event-sourcing
pipeline (ADR-017) is for log-derived domain facts. Forcing crafts
into the domain event log would invent synthetic events that don't
exist in any source-of-truth stream and complicate
`retranslate_from_raw!/0` semantics. Crafts is a snapshot-driven
projection, parallel in shape to `Collection.Diff` itself — pure
function over snapshot pairs, persisted as a derived table.

### Why clean single-card windows only (v1 disambiguation)

Wildcard counts only ever decrement via crafting — pack openings,
draft picks, vault payouts, and rewards never decrement them
(vault payouts *increment* them). So "wildcards of rarity R went
down by N in window W" is unambiguous: N crafts of rarity R
happened. The only ambiguity is **which card** got each wildcard
when window W also contains other card acquisitions (e.g. a pack
opening in the same 30-second sample interval).

For v1, attribute only when:

* exactly one rarity decreased its wildcard count by N, **and**
* exactly one card of that rarity gained copies in the same window,
  **and**
* that card's gain equals N.

When the window contains multiple acquisitions of the matching
rarity, log a thinking-log warning and skip — but the snapshot pair
remains in `collection_snapshots` / `collection_diffs`, so a smarter
v2 attributor can re-process windows we skipped.

This is forward-only and never wrong. It is intentionally lossy for
contested windows. We do not yet know the miss rate — if data shows
contested windows are common, v2 can cross-reference `domain:events`
for pack/draft grants in the same window and subtract those before
attributing the residual to crafts. That coupling is not paid for
until measurement justifies it.

### Why vault payouts are out of scope

A vault payout *increments* wildcard counts, not decrements them. It
is a separate domain concept (a reward, not a spend) and does not
share attribution mechanics with crafting. If/when we want a vault
payout log, it's a follow-up ADR with its own attribution rule
("rarity went up by N, no corresponding wildcard-track event seen")
— the ledger may share the same UI section but the data shape is
different. v1 ignores `wildcards_*` increases entirely.

## Design

### Data model

**New table `crafts`** (one row per detected craft, idempotent on
the to-snapshot+arena_id pair):

| Column | Type | Notes |
|---|---|---|
| `id` | integer pk | |
| `occurred_at_lower` | utc_datetime_usec | `from_snapshot.snapshot_ts` — earliest possible craft time |
| `occurred_at_upper` | utc_datetime_usec | `to_snapshot.snapshot_ts` — latest possible craft time |
| `arena_id` | integer | the crafted card's MTGA id (joins to `cards_cards.arena_id`) |
| `rarity` | string | `"common" \| "uncommon" \| "rare" \| "mythic"` |
| `quantity` | integer | wildcards spent (≥ 1) |
| `from_snapshot_id` | references(:collection_snapshots, on_delete: :nilify_all) | nullable so a baseline (first snapshot) can still attribute on later windows; in practice always set |
| `to_snapshot_id` | references(:collection_snapshots, on_delete: :nilify_all), null: false | the snapshot whose diff revealed the craft |
| `inserted_at` / `updated_at` | utc_datetime_usec | |

Indexes:

* `unique_index(:crafts, [:to_snapshot_id, :arena_id])` — idempotency.
  Replaying attribution over the same diff produces the same row.
* `index(:crafts, [:occurred_at_upper])` — newest-first listing.
* `index(:crafts, [:arena_id])` — per-card history lookups.

We do not enforce a DB FK to `cards_cards.arena_id` because the card
synthesis (ADR-035) is a separate concern; if a crafted card is not
yet in the local `cards_cards` (rotated, brand-new release) the
craft row still persists and the UI shows "Unknown card #<arena_id>"
until synthesis catches up.

Cross-context FK to `collection_snapshots` is acceptable — the
same pattern is used by `match_economy_summaries` (ADR-036). It is
a pure-data audit reference, not a control-flow coupling.

### Attribution pipeline

```
collection_snapshots               (existing, owned by Collection)
  → SnapshotDiff (existing)
    → broadcasts {:diff_saved, diff} on collection:diffs
      → Crafts.IngestCollectionDiffs (new GenServer subscriber)
        → AttributeCrafts.attribute(prev_snapshot, next_snapshot)
          → [%Crafts.Attribution{arena_id:, rarity:, quantity:}]
            → Crafts.persist_attributions/3 (transaction, on_conflict: nothing)
              → broadcasts {:crafts_recorded, [Craft.t()]} on crafts:updates
```

`Scry2.Crafts.AttributeCrafts` is a **pure function module**:

```elixir
@spec attribute(Snapshot.t() | nil, Snapshot.t()) :: [Attribution.t()]
def attribute(nil, _next), do: []           # baseline — nothing to attribute
def attribute(prev, next) do
  prev
  |> wildcard_decreases(next)              # %{rarity => spend_count}
  |> Enum.map(&match_single_card_gain(&1, prev, next))
  |> Enum.reject(&is_nil/1)
end
```

`Scry2.Crafts.Attribution` is a small typed struct:

```elixir
@enforce_keys [:arena_id, :rarity, :quantity]
defstruct [:arena_id, :rarity, :quantity]

@type rarity :: :common | :uncommon | :rare | :mythic
@type t :: %__MODULE__{
  arena_id: integer(),
  rarity: rarity(),
  quantity: pos_integer()
}
```

`Scry2.Crafts.IngestCollectionDiffs` is a GenServer subscriber that
parallels `Scry2.Events.IngestRawEvents` in shape: subscribes on
init, handles each `{:diff_saved, _}` message by fetching the two
snapshots from the DB, calling `AttributeCrafts.attribute/2`, and
inserting the resulting craft rows in a single Multi. It logs
contested windows via `Log.info(:ingester, ...)` for diagnostic
visibility.

### Why PubSub, not in-Multi

Putting attribution inside `Collection.save_snapshot/1`'s Multi
would couple Collection to Crafts at write time. The current
project rule (CLAUDE.md, "All cross-context communication goes
through `Scry2.Topics` PubSub helpers") says no. Async via PubSub:

* Keeps Collection unaware of Crafts.
* Lets `Crafts.replay!/0` re-process every historical
  `Collection.Diff` by simply iterating snapshot pairs in order — no
  need to re-run the snapshot capture.
* Brief consistency gap (snapshot in DB before craft row): tolerable
  for a UI projection. The next LiveView update fixes it.

### Replay

`Scry2.Crafts.replay!/0` walks `collection_snapshots` ordered by
`snapshot_ts`, runs `AttributeCrafts.attribute/2` over each
consecutive pair, and upserts. Idempotent via the
`(to_snapshot_id, arena_id)` unique index. Used for backfill on
first deploy and for re-running attribution after rule changes.

### PubSub topic

New helper in `Scry2.Topics`:

```elixir
@doc "Crafts detected from collection snapshot diffs."
def crafts_updates, do: "crafts:updates"
```

`IngestCollectionDiffs` broadcasts `{:crafts_recorded,
[Craft.t()]}` after each successful insert batch. Empty batches
(window had no detected crafts) do not broadcast.

Single-publisher rule (memory note
`feedback_single_publisher_per_topic`): `crafts:updates` has exactly
one publisher — `IngestCollectionDiffs`. Manual recovery flows
(`replay!/0`) call the same private writer, so the topic invariant
holds.

### File layout

```
lib/scry_2/crafts.ex                                # facade / public API
lib/scry_2/crafts/craft.ex                          # Ecto schema for `crafts` table
lib/scry_2/crafts/attribution.ex                    # %Attribution{} struct
lib/scry_2/crafts/attribute_crafts.ex               # pure attribution logic
lib/scry_2/crafts/ingest_collection_diffs.ex        # GenServer subscriber
lib/scry_2_web/components/recent_crafts_card.ex     # UI component on /economy
priv/repo/migrations/<ts>_create_crafts.exs
test/scry_2/crafts/attribute_crafts_test.exs        # pure, async: true
test/scry_2/crafts/craft_test.exs                   # schema, DataCase
test/scry_2/crafts/ingest_collection_diffs_test.exs # integration
test/scry_2/crafts_test.exs                         # facade
```

### UI

A new `RecentCraftsCard` component on `/economy`, beneath the
existing wildcards chart. Renders the most recent N crafts as a
list — for each row: card image (40 × 56 from
`cards_cards.image_uri`), card name, rarity chip (soft variant per
memory `feedback_soft_ui_states`), quantity if > 1, and a relative
timestamp. Empty state: "No crafts tracked yet — this updates
forward-only from the first memory snapshot."

The wildcards step-line chart already on `/economy` stays as-is for
v1. Markers at each spend timestamp can come in a follow-up; the
list is the primary surface the user asked for.

### Test strategy

Following ADR-009 (no GenServer message-protocol tests) and the
project's pure-vs-resource split:

**Pure (`async: true`, factory-built struct literals):**

* `AttributeCrafts.attribute/2`:
  * baseline (prev = nil) → empty list
  * single rare wildcard spent + single rare card gained → one
    attribution
  * single mythic spent + multiple cards gained including a mythic
    pair → skip (contested), empty list
  * multiple rarities decreased simultaneously → independent
    attribution per rarity
  * card count went up but no wildcard decreased → skip (pack
    opening / reward)
  * wildcard decreased but no matching card gained → skip
    (unattributable; logged)
  * vault payout (rarity went up) → ignored, no attribution
  * snapshot with `nil` wildcard fields (scanner-fallback path) →
    empty list (cannot attribute)

**Resource (`DataCase`):**

* `Craft` schema: required-field validation, `rarity` inclusion,
  `quantity > 0`.
* `(to_snapshot_id, arena_id)` unique-index enforcement (replaying
  the same diff produces no duplicate row).
* `Crafts.persist_attributions/3` end-to-end with realistic
  snapshots created via factory.
* `Crafts.replay!/0` over a fixture of three consecutive snapshots.

**Integration (`IngestCollectionDiffs`):**

* Insert two snapshots + one diff via the Collection facade,
  broadcast `{:diff_saved, diff}` to `collection:diffs`. Drain the
  subscriber with `:sys.get_state/1`. Assert that the expected craft
  row exists and that `{:crafts_recorded, _}` was received on
  `crafts:updates`.

**No HTML assertions** — the LiveView mount test for `/economy` is
extended with a craft fixture and asserts the data flow, not the
markup (per ADR-013 / the user-interface skill rules).

### Settings + kill switch

Crafts attribution is gated behind the existing
`collection.reader_enabled` settings flag — when the memory reader
is off, no snapshots are produced, no diffs are broadcast, and
`IngestCollectionDiffs` simply receives nothing. No new toggle is
needed. If we later want a separate "show me crafts" UI toggle that
hides the card without disabling the underlying ingestion, that's
purely a UI flag added in a follow-up.

### Failure modes

| Failure | Behavior |
|---|---|
| Walker fails (`reader_confidence: "fallback_scan"`) | Snapshot persists with `wildcards_*` = nil. Attribution sees `nil` → empty list. No craft row. Forward-only — no error. |
| Window with multiple cards of same rarity gained | Skipped, logged at `Log.info(:ingester, ...)`. Snapshots stay in DB; v2 can re-process. |
| Diff arrives before its referenced snapshots are committed | `IngestCollectionDiffs` reads via `Repo.get/2`; the Multi in `Collection.save_snapshot/1` commits both before broadcasting, so the read always sees them. If a future change moves broadcast outside the transaction, this assumption breaks — guard with a `:diff_saved` payload that includes the snapshot rows directly. |
| Craft is detected, then user reverses (wildcard granted back) | Two distinct events. v1 records both — UI shows the reversal as a vault-style increase, but vault is out of scope so the increase is silently ignored. The original craft record is preserved. |
| Replay over already-attributed diffs | Idempotent via the unique index. `on_conflict: :nothing`. |
| Card not in `cards_cards` (rotated, brand-new) | Craft row persists; UI renders "Unknown card #<arena_id>" until synthesis catches up. |
| Two snapshots taken with no time between them (stale read) | `prev == next` for all fields → no decreases → no attributions. |

### Implementation order

1. Migration `create_crafts` + `Craft` schema + factory helpers
   (`build_attribution`, `build_craft`, `create_craft`).
2. `Attribution` struct + `AttributeCrafts.attribute/2` (TDD —
   tests first per memory `feedback_test_first`).
3. `Crafts` facade: `list_recent/1`, `persist_attributions/3`,
   `replay!/0`, `count/0`. Tests via `DataCase`.
4. `Topics.crafts_updates/0` helper.
5. `IngestCollectionDiffs` GenServer + supervisor wiring +
   integration test.
6. `RecentCraftsCard` component + integration into
   `Scry2Web.EconomyLive` (data-flow assertions, no markup).
7. Run `Crafts.replay!/0` once on first deploy via a one-shot Oban
   job or a `mix` task — TBD when we land step 6, since the user
   may want a UI button instead.

Each step ends with `mix precommit` clean.

## Consequences

* Good, because the user finally sees per-craft attribution — the
  feature they actually want — built on infrastructure already in
  place. No walker changes, no new sampling, no new event types.
* Good, because attribution is a pure function over snapshot pairs.
  Easy to unit-test, easy to replay, easy to evolve toward smarter
  disambiguation in v2 without re-capturing data.
* Good, because the wildcards chart already on `/economy` stays
  unchanged — the new card augments it rather than replacing it.
* Good, because contested windows are visible (logged) but not
  fabricated. Data integrity preserved. Snapshots that produced
  ambiguous diffs remain in the DB, ready for v2 re-attribution.
* Good, because the cross-context FK to `collection_snapshots`
  gives an audit trail: every craft row points back at the exact
  before/after snapshots that produced it.
* Bad, because v1 silently drops contested windows. If pack-opening
  and crafting commonly fall in the same sample window the user
  will see a craft history with gaps. Mitigation: log a count of
  skipped windows so we can measure the miss rate before deciding
  on v2.
* Bad, because the craft history is forward-only — there is no way
  to recover crafts performed before the first memory snapshot.
  This is intrinsic to the data source (the log doesn't carry the
  signal anymore). Surface explicitly in the UI empty state.
* Bad, because we add another GenServer to the supervision tree
  and another bounded context with its own schema and tests. The
  surface is small but it is non-zero.

## Related

* ADR-034 (memory-read collection) — walker and snapshot
  infrastructure used as-is
* ADR-035 (replace 17lands with MTGA + Scryfall) — `cards_cards.arena_id`
  is the join key the UI uses to render card name + image
* ADR-036 (match economy capture) — precedent for a snapshot-derived
  bounded context that owns its own table and trigger
* ADR-027 (precompute in projections) — `crafts` row is a precomputed
  fact, not a join-time aggregation
* ADR-013 (LiveView logic extraction) — UI logic extracted into the
  card component, tested as pure functions
* ADR-009 (GenServer API encapsulation) — `IngestCollectionDiffs`
  tested through public API only
* `plans/read-wildcard-spends-from-runtime.md` — research note that
  preceded this ADR (now superseded by it)
* Memory note `project_mtga_collection_not_in_log` — confirms the
  Aug 2021 log-fidelity reduction this design works around
