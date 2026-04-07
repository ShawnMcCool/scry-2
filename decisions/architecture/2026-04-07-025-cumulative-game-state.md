---
status: accepted
date: 2026-04-07
---
# Maintain cumulative game state across GRE messages

## Context and Problem Statement

MTGA's GRE protocol uses **differential game state updates**. A `GameStateMessage` can be a full snapshot or a partial delta. Data needed to translate one event (e.g., resolving card instance IDs to arena_ids) may have been sent in a preceding event rather than the current one.

This was discovered when mulligan translation failed to extract hand cards: the `MulliganReq` message contained hand zones with `objectInstanceIds` but zero `gameObjects` to resolve them. The `gameObjects` appeared in a `GameStateMessage` 1–11 events earlier.

Every mature MTGA tracker (17lands client, Untapped.gg companion, gathering-gg, mtgap) solves this by maintaining a running game state across all messages. This is not optional — it is fundamental to how MTGA's log format works.

## Decision Outcome

The `IngestRawEvents` GenServer maintains a **cumulative game object map** in `match_context` across all `GreToClientEvent` messages within a match. Every `GameStateMessage` with `gameObjects` contributes to this map. The translator receives this accumulated state and uses it as fallback when the current message lacks the data needed.

### Rules

1. **Merge, don't replace.** Each `GameStateMessage` with `gameObjects` merges its `instanceId → grpId` mappings into the running map. A new message may add objects, but should not discard previously seen ones unless explicitly removed.

2. **Respect `diffDeletedInstanceIds`.** When MTGA sends a differential update with deleted instance IDs, remove those from the cached map. This prevents stale references to objects that no longer exist (e.g., cards that were shuffled back or exiled).

3. **Clear on match boundary.** `MatchCompleted` resets the entire cache. Each match starts with a fresh state.

4. **Order is the invariant.** The `IngestRawEvents` GenServer processes events sequentially in Player.log byte order. This ordering guarantee is what makes cumulative state correct — each event sees the state from all events before it.

5. **Translator stays pure.** `IdentifyDomainEvents` receives the accumulated state as an argument via `match_context`. It does not maintain state itself. The GenServer owns the state; the translator is a pure function.

### Current implementation

`match_context[:last_hand_game_objects]` caches the most recently resolved hand as `{seat_id, [arena_id, ...]}`. This is a targeted cache for the mulligan use case. As new translators need instance ID resolution, this should generalize to a full `match_context[:game_objects]` map (`%{instanceId => grpId}`) with proper merge and delete semantics.

### Consequences

* Good, because every translator has access to the full game object map, not just what's in its own message
* Good, because this matches the approach used by every mature MTGA tracker in the ecosystem
* Good, because the translator remains pure — state management is the GenServer's responsibility
* Neutral, because the game object map grows during a match (bounded by ~500 objects max per game) and resets per match
* Neutral, because future translators must be aware that data they need may come from `match_context` rather than the current message — this is documented here as the canonical pattern
