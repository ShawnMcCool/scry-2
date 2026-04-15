# Match Replay Data Capture — Phase 1 Design

**Date:** 2026-04-15
**Status:** Approved
**Scope:** Phase 1 of 3 — data capture only. Query layer and replay UI are future phases.

---

## Goal

Capture every game fact needed to reconstruct a match at priority-window granularity — matching the fidelity of 17lands' play-by-play game viewer. No less.

The approach: a lossless domain event stream. Every state-mutating game fact becomes a typed domain event. Board state at any priority step is reconstructable by replaying the event stream forward from `TurnStarted`. Board state snapshots and permanent lifecycle views are future projections over this stream.

---

## Decisions

- **Storage:** Expand domain events (all new data flows through `IdentifyDomainEvents` as typed structs — no separate game log table).
- **Granularity:** Full priority-window level — every phase transition, every priority assignment, every player decision.
- **Opponent actions:** Explicit for our client (`ClientToGREMessage`). Opponent declarations (attackers, blockers) are extracted from `GameStateMessage` annotations. Opponent priority passes are implicit — inferred from `PriorityAssigned` switching back to us.
- **Board state reconstruction:** Action stream only (A). Board state at any moment is reconstructable by replaying events forward. Snapshots and permanent lifecycle projections are Phase 2/3 work.
- **Module structure:** Translator family (B) — `IdentifyDomainEvents` becomes a thin coordinator; each GRE message type gets a focused translator module.

---

## New Event Taxonomy

12 new typed domain event structs. All 21 existing events are unchanged.

### Turn Structure
Events that mark explicit turn and phase boundaries — currently implicit (inferred from the first annotation of each turn/phase).

| Event | Key Fields | Source |
|---|---|---|
| `TurnStarted` | `mtga_match_id`, `game_number`, `turn_number`, `active_player_seat`, `occurred_at` | `GameStateMessage.turnInfo` on turn number change |
| `PhaseChanged` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `step`, `occurred_at` | `GameStateMessage.turnInfo` on phase/step change |

Phases: `untap`, `upkeep`, `draw`, `main_1`, `begin_combat`, `declare_attackers`, `declare_blockers`, `combat_damage`, `end_combat`, `main_2`, `end`, `cleanup`.

### Priority
The core of priority-window fidelity. Our passes are explicit; opponent passes are implicit.

| Event | Key Fields | Source |
|---|---|---|
| `PriorityAssigned` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `step`, `player_seat`, `occurred_at` | `GameStateMessage` priority field on change |
| `PriorityPassed` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `step`, `occurred_at` | `ClientToGREMessage` PassPriority (our client only) |

### Stack
Fills the gap between `SpellCast` and `SpellResolved` — what's actually on the stack and what we targeted.

| Event | Key Fields | Source |
|---|---|---|
| `AbilityActivated` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `source_arena_id`, `source_instance_id`, `occurred_at` | `GameStateMessage` annotation `AnnotationType_ActivatedAbility` |
| `TriggerCreated` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `source_arena_id`, `source_instance_id`, `trigger_type`, `occurred_at` | `GameStateMessage` annotation `AnnotationType_TriggeredAbility` |
| `TargetsDeclared` | `mtga_match_id`, `game_number`, `turn_number`, `spell_instance_id`, `targets: [{instance_id, arena_id}]`, `occurred_at` | `ClientToGREMessage` SubmitTargets |

### Combat
Declarations for both players — our declarations from `ClientToGREMessage`, opponent's from `GameStateMessage` annotations.

| Event | Key Fields | Source |
|---|---|---|
| `AttackersDeclared` | `mtga_match_id`, `game_number`, `turn_number`, `attackers: [{arena_id, instance_id}]`, `occurred_at` | `ClientToGREMessage` DeclareAttackers (us) or `GameStateMessage` annotation (opponent) |
| `BlockersDeclared` | `mtga_match_id`, `game_number`, `turn_number`, `blockers: [{arena_id, instance_id, blocking_instance_id}]`, `occurred_at` | `ClientToGREMessage` DeclareBlockers (us) or `GameStateMessage` annotation (opponent) |

### Permanent State
Tracks tapped state and stat modifications — makes board state reconstructable without a separate snapshot layer.

| Event | Key Fields | Source |
|---|---|---|
| `PermanentTapped` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `arena_id`, `instance_id`, `occurred_at` | `GameStateMessage.gameObjects[]` isTapped delta |
| `PermanentUntapped` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `arena_id`, `instance_id`, `occurred_at` | `GameStateMessage.gameObjects[]` isTapped delta |
| `PermanentStatsChanged` | `mtga_match_id`, `game_number`, `turn_number`, `phase`, `arena_id`, `instance_id`, `power`, `toughness`, `occurred_at` | `GameStateMessage.gameObjects[]` power/toughness delta |

`PermanentStatsChanged` captures continuous effects (e.g. Giant Growth's +3/+3) that are not modelled as counters. The GRE reports updated power/toughness in `gameObjects[]` after any stat-modifying resolution.

---

## Translator Family Structure

`IdentifyDomainEvents` splits into a coordinator + 4 focused translator modules. The public API is unchanged: `IdentifyDomainEvents.identify(raw_event, match_context) → {[domain_events], updated_match_context}`.

```
IdentifyDomainEvents                   (~80 lines — routes to translators)
├── IdentifyDomainEvents.MatchRoom     ← MatchGameRoomStateChangedEvent
│     → MatchCreated, MatchCompleted
├── IdentifyDomainEvents.ConnectResp   ← GREMessageType_ConnectResp
│     → DeckSubmitted
├── IdentifyDomainEvents.GameStateMessage  ← GREMessageType_GameStateMessage
│     turnInfo      → TurnStarted, PhaseChanged
│     priority      → PriorityAssigned
│     annotations[] → CardDrawn, SpellCast, SpellResolved, LandPlayed,
│                      ZoneChanged, CombatDamageDealt, LifeTotalChanged,
│                      TokenCreated, CounterAdded, PermanentDestroyed,
│                      CardExiled, AbilityActivated, TriggerCreated,
│                      AttackersDeclared (opponent), BlockersDeclared (opponent)
│     gameObjects[] → PermanentTapped, PermanentUntapped, PermanentStatsChanged
│     game result   → GameCompleted
└── IdentifyDomainEvents.ClientToGRE   ← ClientToGremessage
      PassPriority          → PriorityPassed
      SubmitTargets         → TargetsDeclared
      DeclareAttackers      → AttackersDeclared
      DeclareBlockers       → BlockersDeclared
      ConcedeReq            → GameConceded          (existing)
      MulliganResp          → MulliganDecided        (existing)
      ChooseStartingPlayer  → StartingPlayerChosen   (existing)
```

`IngestRawEvents` (the GenServer that calls `identify/2`) requires no changes — the coordinator's signature is identical.

---

## Match Context Expansion

The `match_context` map threaded through `IngestRawEvents` gains 3 new fields for delta detection and instance resolution:

| Field | Type | Purpose |
|---|---|---|
| `game_objects` | `%{instance_id => arena_id}` | Full accumulated map across all `GameStateMessage` payloads. Replaces the targeted `last_hand_game_objects`. Used by all translators to resolve `instance_id → arena_id`. |
| `turn_phase_state` | `%{turn: integer, phase: atom, step: atom}` | Current turn/phase/step. `TurnStarted` and `PhaseChanged` emit only when these values change. |
| `game_object_states` | `%{instance_id => %{tapped: bool, power: int, toughness: int}}` | Per-object state snapshot. `PermanentTapped`, `PermanentUntapped`, and `PermanentStatsChanged` emit only when values differ from this map. |

`last_hand_game_objects` is superseded by `game_objects` and removed.

---

## Testing

All tests follow existing conventions: pure function tests (`async: true`, no DB), real MTGA log fixtures, one test per event type, append-only regression test policy (ADR-010).

### New Fixtures Required

| Fixture | Covers |
|---|---|
| `client_to_gre_pass_priority.log` | `PriorityPassed` |
| `client_to_gre_declare_attackers.log` | `AttackersDeclared` (our declaration) |
| `client_to_gre_declare_blockers.log` | `BlockersDeclared` (our declaration) |
| `client_to_gre_submit_targets.log` | `TargetsDeclared` |
| `gre_game_state_phase_change.log` | `TurnStarted`, `PhaseChanged` |
| `gre_game_state_permanent_tap.log` | `PermanentTapped`, `PermanentUntapped` |
| `gre_game_state_stats_changed.log` | `PermanentStatsChanged` (continuous effect) |

### Delta Detection Tests

These correctness cases are critical — wrong delta logic produces duplicate or missing events:

- Two consecutive `GameStateMessage` payloads in the same phase → exactly one `PhaseChanged`, not two
- `gameObjects[]` entry with `isTapped: true` already in context → no `PermanentTapped` emitted
- `gameObjects[]` power/toughness unchanged from context → no `PermanentStatsChanged` emitted

### Match Context Accumulation Test

Verify `game_objects` map builds correctly across a sequence of `GameStateMessage` payloads, and `instance_id → arena_id` resolution succeeds for an object first seen three messages earlier.

### Scenario Integration Test

The combat exchange from the design session — attacker declared, blocker declared, pump spell cast with targets, spell resolves, combat damage, creature destroyed — asserted as a complete ordered event sequence of 22 events.

---

## Out of Scope (Phase 1)

- New projections (no new database tables)
- Query layer ("board state at turn X")
- Replay UI
- Opponent priority pass synthesis (opponent passes are implicit — `PriorityAssigned` switching back to us is the signal)

---

## Verification

1. Run `mix test` — all existing tests pass, new translator tests pass
2. Run `mix precommit` — zero warnings
3. Ingest a real `Player.log` with a multi-game match
4. Query `Scry2.Events` for the match — verify `TurnStarted`, `PhaseChanged`, `PriorityAssigned`, `PriorityPassed`, `AttackersDeclared`, `BlockersDeclared`, and `PermanentStatsChanged` events appear with correct values
5. Confirm existing match/game projections are unaffected
