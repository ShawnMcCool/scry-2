---
status: exploratory
date: 2026-04-30
revised: 2026-04-30
---
# Opponent game-state memory read — feasibility & blueprint

> **Revision 2026-04-30:** spike 16
> (`mtga-duress/experiments/spikes/spike16_match_manager/FINDING.md`)
> validated both Chain 1 and Chain 2 end-to-end against live MTGA.
> Anchors are verified; field offsets are pinned in the
> `mono-memory-reader` skill. **The original "one-shot at
> `MatchCompleted`" capture model is superseded** — see "Decision
> Outcome" below — because MTGA resets all PlayerInfo values to
> placeholders and nulls `MatchSceneManager.Instance` by the time the
> log event reaches us. Live polling, gated by `MatchCreated` →
> `MatchSceneManager.Instance == NULL`, is now the recommended path.

## Context and Problem Statement

The match detail page (`/matches/<id>`) needs to display the opponent's
deck — at minimum, the cards the opponent revealed during the match.
There is no opponent-deck data persisted today: log-derived gameplay
events (`spell_cast`, `zone_changed`, `card_drawn`, etc.) carry
`player_id` and would let us derive a "cards seen" set, but no projection
rolls them up, and the log path has known gaps:

- Opponent rank is **not** present in MTGA's match-room events
  (memory record `project_mtga_no_opponent_rank.md`). The log can never
  fill this column.
- Opponent commander grpIds are not reliably emitted in match-creation
  events for Brawl/Commander formats.
- Some board-state details (face-down reasons, alt-art overlay grpIds,
  exact stack ordering at a moment) require deeper GRE message parsing
  than we currently do.

This record investigates whether MTGA's process memory exposes opponent
game-state in a usable shape, and — if so — what the implementation
contour looks like.

## Decision Drivers

- The existing memory-reader subsystem (`Scry2.Collection`,
  ADR-034) already ships in production. Extending it costs less than
  adding a parallel data source.
- Project posture: "we may not have COMPLETE data, but we'll have
  SOME" — partial visibility (revealed-only, no library identities)
  is acceptable.
- Linux-first; read-only via `process_vm_readv`; no injection.
- Patch-resilient against MTGA's ~2-week cadence — every offset
  validated against two independent sources before pinning (see
  `.claude/skills/mono-memory-reader`).
- The Untapped.gg companion (analysed in
  `mtga-duress/experiments/untapped-analysis/`) reads exactly this
  shape — strong feasibility signal.

## Considered Options

### Avenue A — Log-derived projection only

Stand up a new projection (`matches_opponent_cards_seen` or similar)
that subscribes to `domain:events`, filters gameplay events by
`player_id != self`, aggregates `(match_id, arena_id, count_seen)`.

- **Pros**: No memory-reader work; pure event-sourced; replayable.
- **Cons**: Cannot fill opponent-rank / commander-grpId gaps;
  granularity bounded by what `IdentifyDomainEvents` already
  translates; some zones (face-down reasons, exact reveal moments)
  not currently tracked.

### Avenue B — Memory read of in-match state (this record)

Extend the Rust walker (`native/scry2_collection_reader/`) with a
new traversal anchored at MTGA's `MatchSceneManager` singleton, walking
through `_gameManager.CardHolderManager._provider.PlayerTypeMap` to
read every zone for every player. Capture either at `MatchCompleted`
log event (one-shot) or via a continuous-poll subsystem (`live` mode).

- **Pros**: Authoritative client view; closes log gaps (rank,
  commander, alt-art overlay); already proven feasible by Untapped.
- **Cons**: New walker module; new schema; capture-timing risk for
  one-shot model; live polling = new architectural mode.

### Avenue C — A + B in tandem

Memory read at `MatchCompleted` snapshots authoritative revealed-card
set + rank + commander; log-derived projection fills in moment-by-
moment gameplay history (when each card was first seen, etc.). The
two views reconcile: memory is ground truth at end-of-match; log is
the timeline.

- **Pros**: Defence in depth; if memory read fails (process gone,
  scene torn down, MTGA patch broke offsets), log-derived path still
  works.
- **Cons**: Two sources to maintain; reconciliation logic.

## Findings — feasibility verified

The Untapped companion reads MTGA in-match game state via two
independent pointer chains. Both are recovered in full from
`mtga-duress/experiments/untapped-analysis/source-maps/`. Per the
clean-room rule documented in
`mtga-duress/experiments/untapped-analysis/DOSSIER.md`, the *idea*
(pointer chain, field names) is not copyrightable; the *expression*
(their code) is. We use the chain as a blueprint, not as a source.

### Chain 1 — match info (rank, commander)

Source: `ScryIpcHandler-x0rjOwCx/src/scry/readers/mtga/ScryMtgaMatchInfo.ts`.

```
PAPA._instance.MatchManager
  ├── Event.PlayerEvent.Format.UseRebalancedCards : bool
  ├── LocalPlayerInfo
  │     ├── RankingClass : enum[None, Bronze, …, Mythic]
  │     ├── RankingTier : int
  │     ├── MythicPercentile : float
  │     ├── MythicPlacement : int
  │     └── CommanderGrpIds : List<int>
  └── OpponentInfo
        ├── RankingClass, RankingTier, MythicPercentile, MythicPlacement
        └── CommanderGrpIds : List<int>
```

This chain anchors at the existing `PAPA` singleton — same anchor
the inventory walker already uses. Reusable infrastructure.

### Chain 2 — board state (every card in every zone, both players)

Source:
- `ScryIpcHandler-x0rjOwCx/src/scry/readers/mtga/ScryMtgaMatchReader.ts`
- `ScryIpcHandler-x0rjOwCx/src/scry/utils/types/mtga/MatchSceneManager.ts`
- `ScryIpcHandler-x0rjOwCx/src/scry/utils/mtga/ScryBattlefieldStacks.ts`
- `ScryIpcHandler-x0rjOwCx/src/scry/utils/mtga/ScryMatchZone.ts`

```
mtgaMatchSceneManager (singleton — anchor TBD; see Open Questions)
  ._gameManager
    .CardHolderManager._provider.PlayerTypeMap
      Dict<GREPlayerNum, Dict<CardHolderType, ICardHolder>>
        [LocalPlayer | Opponent | Teammate | Invalid]
          [Library | Hand | Battlefield | Graveyard | Exile |
           Stack | Command | OffCameraLibrary | …]
            ._previousLayoutData : List<CardLayoutData>
            (BattlefieldCardHolder.Layout splits into
             _localCreatureRegion / _opponentCreatureRegion / Lands /
             Artifacts / Planeswalkers — each a BattlefieldRegion
             with _stacksByShape : Dict<int, List<BattlefieldStack>>,
             each stack carrying AllCards : List<BaseCDC>)

CardLayoutData
  ├── IsVisibleInLayout : bool
  └── Card : BaseCDC
        └── _model : CardDataAdapter
              ├── _printing : CardPrintingData (full Scryfall-shape data)
              └── _instance
                    ├── BaseGrpId : int           ← arena_id
                    ├── OverlayGrpId.value : int  ← alt-art arena_id
                    ├── IsTapped : bool
                    └── FaceDownState._reasonFaceDown : enum
```

### What is readable for the opponent

| Zone (opponent) | Identities readable? |
|---|---|
| Battlefield (creatures/lands/artifacts/walkers) | ✅ all |
| Graveyard | ✅ all |
| Exile | ✅ all |
| Stack (while on stack) | ✅ |
| Command zone | ✅ all |
| Hand — revealed cards | ✅ (`BaseGrpId` populated) |
| Hand — face-down cards | ⚠️ count + `FaceDownState`, no `BaseGrpId` |
| Library | ❌ count only — client never has unrevealed identities |

The "opponent's deck" we can render = union of every card with a
populated `BaseGrpId` across all opponent zones, accumulated across
the duration of the match. Plus `OpponentInfo.CommanderGrpIds` for
Brawl/Commander.

### Capture model trade-offs

- **One-shot at `MatchCompleted`**: log event triggers a single
  walker run, snapshot is persisted to a new projection. Existing
  event-driven architecture; no new subsystem. Risk: MTGA may tear
  down `mtgaMatchSceneManager` or its zones at match end before
  the read fires. Mitigation: graceful-degrade — empty snapshot
  is acceptable (Avenue C falls back to log-derived data).
- **Live polling** (`Scry2.LiveState` GenServer in `plans.md`,
  ~4 Hz during active match): accumulates revealed cards across
  the match into a rolling set. No timing risk. Cost: full new
  subsystem with kill switch, settings gate, isolation per
  ADR-034 conventions. Unlocks adjacent capabilities (HUD feed,
  draft tracker, mana/card-advantage analytics — see
  `plans.md` section D).

For "show opponent deck on match page," one-shot is the minimum
viable capture. Live polling is the right long-term answer but
not the right first step.

## Decision Outcome (revised 2026-04-30)

**Recommended path: Avenue C (memory + log) with live polling
during the match.**

The original recommendation was a one-shot read at `MatchCompleted`.
Spike 16 invalidated that: MTGA resets `LocalPlayerInfo` /
`OpponentInfo` to placeholder defaults and nulls
`MatchSceneManager.Instance` before the `MatchCompleted` log event
reaches us. By read time, the data is gone.

**Live-polling state machine (`Scry2.LiveState`, plans.md section D):**

```
IDLE
  → MatchCreated log event (subscribe to domain:events)
                       ↓ start polling at ~250 ms
POLLING
  • walker reads Chain 1 (rank, opponent name, commander grpIds)
  • walker reads Chain 2 (revealed cards, accumulating across the match)
  • on every tick: check MatchSceneManager.Instance
       ── NULL → WINDING_DOWN
  • backstop: MatchCompleted log event OR 90-min timeout → WINDING_DOWN
                       ↓
WINDING_DOWN
  • persist final rolling snapshot (rank + screen-name + revealed-cards set)
  • broadcast match_state:final to UI subscribers
                       ↓
IDLE
```

**Implementation phases:**

1. **Phase 1 — `walker/match_info.rs` for Chain 1.** Smallest piece;
   reuses existing `PAPA` anchor + field-resolution machinery; ships
   "opponent rank + real screen name on the match page." No
   GenServer yet — exposed as a NIF the Elixir side can call once
   on demand.
2. **Phase 2 — generic Dictionary + List<T> walker primitives.**
   Extends `dict.rs` to handle non-`<int,int>` generics; new
   `list.rs` module. Prerequisite for Chain 2.
3. **Phase 3 — `walker/match_scene.rs` for Chain 2.** Walks
   `MatchSceneManager.Instance → _gameManager → CardHolderManager →
   _provider → PlayerTypeMap` and iterates the opponent's zones.
   Returns a flat set of `(arena_id, zone, face_down?)` tuples.
3. **Phase 4 — `Scry2.LiveState` GenServer.** Subscribes to
   `domain:events` for `MatchCreated` / `MatchCompleted`; calls the
   NIF on each tick; accumulates revealed-cards set; broadcasts on
   `match_state:updates`; persists at end-of-match. Settings flag
   for enable/disable + manual kill switch per ADR-034 conventions.
5. **Phase 5 — `Scry2.MatchSnapshots` schema + persistence.** Stores
   final per-match snapshot: opponent rank/screen-name/commander +
   revealed-card set. Matches by `mtga_match_id`. Read by the
   match-detail LiveView.

Phases 1 and 4 each unlock distinct user-facing wins. Phase 1 alone
solves the original "show opponent rank on the match page" need.
Phases 2–4 add the in-match revealed-cards display; Phase 5 makes
it persistent.

Rationale: the blueprint is fully recovered, both anchors are
verified, and live polling is the only viable capture model given
MTGA's tear-down behaviour. Stopping at log-derived data would
leave opponent rank and screen name permanently broken.

## Open Questions

- ~~**Anchor location for `mtgaMatchSceneManager`.**~~ **RESOLVED**
  — `MatchSceneManager` class has a static `Instance` field at
  offset `0x0000` (attrs `0x0016`). Verified by spike 16.
- **Generic `Dictionary<K, V>` walker.** The current crate handles
  `Dictionary<int, int>` for the inventory cards collection. Chain 2
  uses `Dictionary<GREPlayerNum, Dictionary<CardHolderType, ICardHolder>>`
  — same Mono internal layout (`_entries` array of 16-byte
  `Entry<K,V>` records), but different value-type sizes. Audit the
  existing dict reader for generic-sound assumptions.
- **`List<T>` walker.** `_previousLayoutData` is `List<CardLayoutData>`.
  Mono's `List<T>` is `T[] _items + int _size + int _version`. Need
  a small reader module.
- ~~**Tear-down timing at `MatchCompleted`.**~~ **RESOLVED** — by
  the time `MatchCompleted` reaches us via the log,
  `MatchSceneManager.Instance` is NULL and both PlayerInfo objects
  are reset to placeholder defaults. One-shot capture at log-event
  time is **not viable**. Live polling is required.
- **`MythicPercentile` byte width.** i32 vs f32 unresolved — both
  read 0 for sub-Mythic players. Default to i32 in the walker;
  re-verify on a future read with a Mythic-tier player visible.
- **Reconciliation with log-derived data.** When memory-read snapshot
  and log-derived "cards seen" diverge, which is authoritative?
  Memory should be — but the divergence itself is diagnostic of
  parser gaps and should be surfaced.

## Subsequent ADRs

This record's findings should be picked up by:

1. An ADR for the `MatchManager` walker extension (rank/commander
   read; one-shot at match-page load).
2. An ADR for the `MatchSceneManager` walker extension and the
   `Scry2.MatchSnapshots` context (board-zone read; one-shot at
   `MatchCompleted`).
3. A future ADR for the live-polling subsystem (`Scry2.LiveState`)
   when its capabilities are needed.

## References

- `decisions/architecture/2026-04-22-034-memory-read-collection.md`
  — the parent ADR; walker-in-Rust decision and NIF contract.
- `.claude/skills/mono-memory-reader/SKILL.md` — canonical pointer-chain
  and offset reference; this record's findings extend that document.
- `mtga-duress/experiments/untapped-analysis/DOSSIER.md` — clean-room
  boundary statement and Untapped architecture summary.
- `mtga-duress/research/002-mtga-memory-reader-design.md` — the
  prior research record this builds on.
- `plans.md` — section C (pre/post-match capture) and section D
  (live tracking) frame how this work composes with the broader
  capability roadmap.
- Untapped recovered sources (blueprint only — clean-room rule):
  - `mtga-duress/experiments/untapped-analysis/source-maps/ScryIpcHandler-x0rjOwCx/src/scry/readers/mtga/ScryMtgaMatchInfo.ts`
  - `mtga-duress/experiments/untapped-analysis/source-maps/ScryIpcHandler-x0rjOwCx/src/scry/readers/mtga/ScryMtgaMatchReader.ts`
  - `mtga-duress/experiments/untapped-analysis/source-maps/ScryIpcHandler-x0rjOwCx/src/scry/utils/types/mtga/MatchSceneManager.ts`
