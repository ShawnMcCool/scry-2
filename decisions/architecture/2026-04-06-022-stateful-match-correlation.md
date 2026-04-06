---
status: accepted
date: 2026-04-06
---
# Stateful match correlation in IngestRawEvents

## Context and Problem Statement

Some MTGA events (mulligan offers, in-game GRE diffs) don't carry
their match ID or game number. These fields appear only in the initial
`MatchGameRoomStateChangedEvent` (Playing) and the first full
`GameStateMessage` (in the ConnectResp batch). Subsequent GRE events
use `GameStateType_Diff` messages that omit `gameInfo.matchID` and
`gameInfo.gameNumber`.

To produce meaningful domain events from these in-game messages (e.g.
`%MulliganOffered{}` tagged with the correct match), the translator
needs context that isn't in the raw event itself.

## Decision Outcome

Chosen option: "lightweight state in IngestRawEvents", because there
is only ever one active match at a time (single-player MTGA client),
and the GenServer already has state.

### What IngestRawEvents tracks

The GenServer state gains a `match_context` map:

```elixir
%{
  current_match_id: String.t() | nil,
  current_game_number: non_neg_integer() | nil
}
```

Updated at specific domain event boundaries:

- **Set `current_match_id`** when `IdentifyDomainEvents.translate/2`
  produces a `%MatchCreated{}`. The match_id comes from the domain
  event, not from state.
- **Set `current_game_number`** when a `%DeckSubmitted{}` is produced
  (marks the start of each game — ConnectResp fires per game including
  after sideboarding).
- **Clear both** when a `%MatchCompleted{}` is produced.

### How it's used

`IdentifyDomainEvents.translate/3` gains a third argument: the
match_context map. The translator remains a pure function — it
receives context as input, doesn't mutate it. IngestRawEvents is
responsible for maintaining the context and passing it.

Domain events that need context (e.g. `%MulliganOffered{}`) receive
`match_id` and `game_number` from the context. If context is nil
(edge case: events before the first match), those fields are nil on
the domain event — the discrete fact is still recorded.

### Consequences

* Good, because in-game events get correct match/game correlation
  without multi-event scanning or post-hoc enrichment
* Good, because the translator stays pure — state flows in, not out
* Good, because the state is minimal (2 fields) and has clear
  lifecycle (set on match start, clear on match end)
* Bad, because state introduces ordering sensitivity — if events
  arrive out of order (unlikely in single-process PubSub), context
  could be wrong
* Bad, because replaying events via `retranslate_from_raw!/0` must
  also replay through IngestRawEvents (which it already does) to
  maintain correct context
