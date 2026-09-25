---
status: accepted
date: 2026-09-25
---
# Revealed cards come from the domain event log, not from process memory

## Context and Problem Statement

The match detail page shows a **Revealed cards** section: the cards whose
identity the local MTGA client learned during a match, grouped by seat
and zone. It has been sourced from Chain 2 of the memory walker — the
`MatchSceneManager` → `CardHolderManager` → `ICardHolder` pointer chain
in `native/scry2_collection_reader` — persisted to `live_match_board_snapshots`
and `live_match_revealed_cards`.

Two independent failures exposed the design rather than a bug in it.

**Phantom cards (GitHub issue #3, 2026-09-03).** A user reported the
section showing cards present in neither player's deck, including cards
not legal in the match's format. Reproduced in the maintainer's own data:
of 1,941 revealed cards attributed to the local seat in the Hand zone,
36 are absent from that match's own submitted decklist. The contaminants
are valid, coherent cards clustered per match and often drawn from a
single unrelated deck — five Theros Beyond Death cards appearing in one
Direct Challenge, for instance. They are real `BaseGrpId` values read off
real card-display objects; the walker is reading the *wrong objects*.

The non-battlefield zones read `CardHolderBase._previousLayoutData` — the
*previous* layout pass — filtered only by `IsVisibleInLayout` and
`BaseGrpId != 0`. Unity pools card display objects; a recycled object
retains the grpId of whatever it last rendered. Nothing ties an entry to
the zone's current contents.

**Total failure after an MTGA update (2026-09-25).** On build
`ca505c18e9…` (previously `8da7e26e8d…`) the hand, graveyard and exile
zones return nothing at all. Verified live: five cards in hand, zero
reported. Every struct the path depends on still resolves
(`CardLayoutData.<IsVisibleInLayout>` @72, `CardHolderBase._previousLayoutData`
@168, the `HandCardHolder` / `GraveyardCardHolder` / `PlayerExileCardHolder`
classes), so this is not a renamed field — the buffer is simply no longer
populated the way the walker assumes.

Repairing the walker — pointing it at `_laidOutCdcCache` @184 instead —
would restore the feature and leave the design untouched. The design is
the problem.

## Decision Drivers

* MTGA's memory layout is not a contract. Every client update can move it.
* Raw log events are already persisted for replay (ADR-015), so anything
  derived from them is rebuildable. Walker output was stored only in its
  interpreted form — a reader bug is unrecoverable.
* `live_match_*` rows bypass the event-sourced pipeline entirely (ADR-017),
  making them a second, unreconciled representation of "cards in this match".
* Event sourcing is the core ingestion architecture; a direct-write side
  channel contradicts it.

## Considered Options

1. **Repair the walker.** Point the non-battlefield path at
   `_laidOutCdcCache`. Cheapest, restores the status quo including the
   phantom-card bug, and re-breaks at the next MTGA update.
2. **Repair the walker and validate against the decklist.** Detect
   contradictions and suppress them. Adds a reconciliation layer over a
   source that should not need one.
3. **Source revealed cards from the domain event log; retire Chain 2
   board reading.** Chosen.

## Decision Outcome

Chosen: **option 3**.

MTGA's game-rules engine tells the client what to render. Reading the
renderer's memory to discover what the client was told is reading the
shadow instead of the object — and the object is already captured. The
GRE `GameStateMessage` carries the full picture in every raw event:

```json
{ "zones": [ { "zoneId": 31, "type": "ZoneType_Hand",
               "visibility": "Visibility_Private",
               "objectInstanceIds": [ … ] } ],
  "gameObjects": [ { "instanceId": 358, "grpId": 105159, "zoneId": 28,
                     "ownerSeatId": 1, "controllerSeatId": 1,
                     "visibility": "Visibility_Public",
                     "type": "GameObjectType_Card" } ] }
```

Zone identity, zone *type*, visibility, per-object `grpId`, and an
authoritative `ownerSeatId`. Measured over a 600-row sample of
`GreToClientEvent`, 203 rows carry a `zones` table and 226 carry
`gameObjects` — roughly one in three, across the full history back to
2026-04-07. Every one of the 656 matches holding a board snapshot also
has domain events.

A **revealed card** is therefore defined as: a `GameObjectType_Card`
game object with a non-null `grpId`, attributed to `ownerSeatId`, located
in the zone whose `ZoneType_*` its `zoneId` resolves to. The local
client only ever receives a `grpId` for a card whose identity it has
been shown, which is exactly the feature's intent — no heuristic filter
required.

### Consequences

Good:

* One source of truth. The phantom-card class of bug cannot occur — a
  card is reported iff MTGA told the client it was there.
* Rebuildable. `Scry2.Events.replay_projections!/0` reconstructs the read
  model from preserved raw events; a future bug in the projection is
  recoverable, unlike a bug in a memory read.
* Authoritative seat attribution. 8,706 of 10,733 historical battlefield
  rows carry `seat_id = 0` because `owner_seat_for_cdc` failed; GRE states
  the owner outright.
* Cumulative rather than instantaneous. The persisted board snapshot was
  the last successful poll — one moment. The event log covers the whole
  match, so a card revealed on turn 3 and exiled on turn 5 is still known.
* Immune to MTGA memory-layout changes, which is how this broke twice.
* Net code deletion: `card_holder.rs`, `card_layout_data.rs`, the Chain-2
  half of `run.rs`, and two tables.

Bad / accepted costs:

* Larger than the walker repair — the anti-corruption layer must resolve
  zone ids to `ZoneType_*`, and a new projection is required.
* The historical `live_match_revealed_cards` rows are discarded rather
  than migrated. They are superseded by a replay over the same matches
  from better data, and are known-contaminated. The database is backed up
  through Fae before the dropping migration.
* Zone ids are per-game GRE instance ids, so zone-type resolution must be
  scoped per game, not global.

### Seat number is not seat role

GRE `ownerSeatId` is a per-match seat **number**, and the local player
alternates seats between matches. Measured across the rebuilt event log:
seat 1 is the local player 10,159 times and the opponent 3,419 times;
seat 2 is the local player 3,620 times. The retired memory walker's
`seat_id` meant something different — `ClientPlayerEnum`, where 1 is
always LocalPlayer — so carrying the old "seat 1 = You" assumption into
the new data mislabels roughly a quarter of matches.

The anti-corruption layer therefore resolves the *role* once, as
`owner_is_local`, and the projection stores it as `is_local` alongside
the factual `seat_id`. `Scry2Web.Live.MatchBoardView.seat_label/2` labels
from the role and falls back to `"Seat <n>"` when the role is unknown,
rather than guessing.

**Scheduled convergence.** `CardDrawn.is_self_draw` is the older, narrower
name for exactly `owner_is_local` and still has consumers in `Decks`
(`decks_cards_drawn.is_self_draw`, queried by `Scry2.Decks`). Both now
come from one computation in the ACL, but two names for one fact remain.
Converge when `Decks` next changes shape: drop the column, migrate its
consumers to `owner_is_local`, retranslate.

Two latent bugs surfaced while doing this and are fixed here, because the
zone table this ADR introduces is what they were missing:

* `zone_owners` was keyed by `zones[].id`, a field that does not exist —
  every zone object carries `zoneId`. The map was keyed entirely by `nil`,
  so `is_self_draw` was `nil` on **all 26,469** `card_drawn` events ever
  produced. `Scry2.Decks` filters `is_self_draw = 1`, so that query had
  never matched a row.
* `ZoneChanged.zone_from`/`zone_to` were documented as `"Battlefield"` /
  `"Hand"` but carried `"zone_28"` — `GREProtocol.zone_name/1` only
  prefixed the raw id. That function is deleted; `ZoneTable.label/2`
  replaces it.

### What the memory reader keeps

Chain 2 board reading is retired. Everything else stays — these have no
log equivalent:

| Walk | Status |
|---|---|
| collection | keep — memory is the only source (ADR-034) |
| match_info (Chain 1) | keep — rank, screen names, seats |
| mastery, events, account, cosmetics, environment | keep |
| **match_board (Chain 2)** | **retire** |

## Related

* [ADR-015](2026-04-05-015-raw-event-replay.md) — raw event replay, which
  makes this reconstruction possible.
* [ADR-017](2026-04-05-017-event-sourcing-core-architecture.md) — the
  pipeline this feature now rejoins.
* [ADR-018](2026-04-05-018-anti-corruption-layer-mtga-domain.md) — zone
  type resolution belongs in `IdentifyDomainEvents`, not downstream.
* [ADR-034](2026-04-22-034-memory-read-collection.md) — the memory reader,
  whose remaining walks are unaffected.
