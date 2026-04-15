# MTGA GRE Field Notes

Discovered from Player.log on 2026-04-15. All fields confirmed from real log data.

## GameStateMessage (GSM) — `greToClientEvent.greToClientMessages[].gameStateMessage`

Top-level keys observed: `actions`, `annotations`, `diffDeletedInstanceIds`,
`diffDeletedPersistentAnnotationIds`, `gameInfo`, `gameObjects`, `gameStateId`,
`pendingMessageCount`, `persistentAnnotations`, `players`, `prevGameStateId`,
`timers`, `turnInfo`, `type`, `update`, `zones`.

**There is no top-level `priorityPlayer` key in GSM.** Priority is inside `turnInfo`.

## turnInfo fields

```json
{
  "phase": "Phase_Beginning",
  "step": "Step_Upkeep",
  "turnNumber": 1,
  "activePlayer": 1,
  "priorityPlayer": 1,
  "decisionPlayer": 2,
  "nextPhase": "Phase_Main1",
  "nextStep": "Step_Draw"
}
```

- `turnNumber` — integer, present when a turn has started
- `phase` — string like `Phase_Beginning`, `Phase_Main1`, `Phase_Combat`, `Phase_Main2`, `Phase_Ending`
- `step` — string like `Step_Upkeep`, `Step_Draw`, `Step_BeginCombat`, `Step_DeclareAttack`, `Step_EndCombat`, `Step_End`, `Step_Cleanup`
- `activePlayer` — seat ID of the player whose turn it is
- `priorityPlayer` — seat ID of the player who currently holds priority (may differ from activePlayer)
- `decisionPlayer` — seat ID of the player making a decision (often same as activePlayer)
- `nextPhase` / `nextStep` — upcoming phase/step

Early GSM messages may have only `activePlayer` and `decisionPlayer` with no phase/turn yet.

## gameObjects fields

Sample object with power/toughness:
```json
{
  "instanceId": 123,
  "grpId": 96829,
  "type": "GameObjectType_Card",
  "zoneId": 4,
  "visibility": "Visibility_Public",
  "ownerSeatId": 1,
  "controllerSeatId": 1,
  "superTypes": [...],
  "cardTypes": [...],
  "subtypes": [...],
  "color": [...],
  "power": {"value": 1},
  "toughness": {"value": 3},
  "isTapped": true,
  "viewers": [...],
  "name": "...",
  "overlayGrpId": 0,
  "othersideGrpId": 0,
  "uniqueAbilities": [...]
}
```

- `power` / `toughness` — objects with `{"value": N}`, only present on creature-type objects
- `isTapped` — boolean `true`, only present when tapped (absent when untapped)

## players fields

```json
{
  "systemSeatNumber": 1,
  "lifeTotal": 20,
  "startingLifeTotal": 20,
  "maxHandSize": 7,
  "teamId": 1,
  "controllerSeatId": 1,
  "controllerType": "ControllerType_Player",
  "turnNumber": 1,
  "timerIds": [...],
  "pendingMessageType": "...",
  "status": "..."
}
```

## ClientToGREMessage types

### Pass Priority — `ClientMessageType_PerformActionResp`

Header: `[UnityCrossThreadLogger]<timestamp>: <matchId> to Match: ClientToGremessage`

```json
{
  "requestId": 19,
  "clientToMatchServiceMessageType": "ClientToMatchServiceMessageType_ClientToGREMessage",
  "timestamp": "...",
  "transactionId": "...",
  "payload": {
    "type": "ClientMessageType_PerformActionResp",
    "gameStateId": 6,
    "respId": 19,
    "performActionResp": {
      "actions": [
        {
          "actionType": "ActionType_Play",
          "grpId": 96829,
          "instanceId": 204,
          "facetId": 204,
          "shouldStop": true
        }
      ],
      "autoPassPriority": "AutoPassPriority_Yes"
    }
  }
}
```

- `payload.type` = `"ClientMessageType_PerformActionResp"`
- `payload.performActionResp.autoPassPriority` = `"AutoPassPriority_Yes"` when auto-passing
- `payload.performActionResp.actions` — array of actions taken before passing

### Declare Attackers — `ClientMessageType_DeclareAttackersResp`

```json
{
  "payload": {
    "type": "ClientMessageType_DeclareAttackersResp",
    "gameStateId": 233,
    "respId": 304,
    "declareAttackersResp": {
      "autoDeclare": true,
      "autoDeclareDamageRecipient": {
        "type": "DamageRecType_Player",
        "playerSystemSeatId": 2
      }
    }
  }
}
```

- `payload.type` = `"ClientMessageType_DeclareAttackersResp"`
- `payload.declareAttackersResp.autoDeclare` — boolean, true when MTGA auto-declared
- This sample used auto-declare; a manually declared sample would have an `attackers` array

## Known Phase/Step values observed

Phases: `Phase_Beginning`, `Phase_Main1`, `Phase_Combat`, `Phase_Main2`, `Phase_Ending`

Steps: `Step_Upkeep`, `Step_Draw`, `Step_BeginCombat`, `Step_DeclareAttack`,
`Step_EndCombat`, `Step_End`, `Step_Cleanup`
