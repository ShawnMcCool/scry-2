---
status: accepted
date: 2026-04-08
---
# Enrich domain events at ingestion, not in projectors

## Context and Problem Statement

Projectors currently do significant work beyond simple writes: the mulligans projector looks up card metadata to compute hand stats, the match listing projector queries matches for event names and resolves deck colors from card data. This couples projectors to multiple contexts and makes them stateful in ways that are fragile during replay.

Meanwhile, the ingestion service (`IngestRawEvents`) already maintains rich stateful context: player identity, match correlation, game object maps. It processes events sequentially in order with full context available. This is the natural place to enrich events — not the projectors.

## Decision Outcome

**Domain events should arrive at projectors fully enriched.** All derivation, context resolution, and metadata lookups happen during ingestion (in `IdentifyDomainEvents` or `IngestRawEvents`). Projectors are pure map-and-write — they take a complete event struct and write it to their projection table with no external lookups.

### Rules

1. **Ingestion owns enrichment.** `IngestRawEvents` maintains a stateful context (player rank, match state, game objects, etc.) and stamps derived data onto domain events before appending them. The translator (`IdentifyDomainEvents`) can also enrich from the `match_context` it receives.

2. **Domain events are self-contained.** A `MulliganOffered` event should carry `hand_arena_ids`, `land_count`, `card_names` — everything a projector needs. A `MatchCreated` event should carry `player_rank`, `format`, `format_type`. No projector should need to call `Cards.get_mtga_card` or `Matches.get_by_mtga_id`.

3. **Projectors are dumb writers.** A projector's `project/1` function takes one event and writes one (or a few) rows. No external queries, no card lookups, no match joins. If a projector needs data that isn't on the event, the event is incomplete — fix the ingestion, not the projector.

4. **Stateful context lives in `IngestRawEvents`.** Rank tracking, match correlation, game object caching, player detection — all maintained in the GenServer state. This context is available to the translator and to post-translation enrichment.

5. **Replay rebuilds the context.** When re-ingesting (`reingest!/0`), the stateful context rebuilds naturally as events are re-processed in order. The rank state, match state, and game objects accumulate exactly as they did during live ingestion.

### What moves from projectors to ingestion

| Data | Currently computed in | Moves to |
|------|----------------------|----------|
| `player_rank` | Not captured | `IngestRawEvents` state → stamp on `MatchCreated` |
| `deck_colors` | `Matches.Match` | `IngestRawEvents` or translator → stamp on `DeckSubmitted` |
| `land_count`, `cmc_distribution`, etc. | `Mulligans.MulliganListing` | Translator → stamp on `MulliganOffered` |
| `event_name` on mulligans | `Mulligans.MulliganListing` via match lookup | Already on `MatchCreated` → projector writes directly |
| `format`, `format_type` | `Matches.Match` | Translator → infer from `event_name`, stamp on `MatchCreated` |

### Consequences

* Good, because projectors are simple, fast, and have no external dependencies
* Good, because domain events are the complete historical record — everything derivable at ingestion time is preserved
* Good, because replay is deterministic — projectors don't depend on card metadata that might change between replays
* Good, because testing projectors is trivial — just pass a struct, assert the DB write
* Neutral, because domain event structs grow larger — but storage is cheap and they're already JSON blobs
* Neutral, because ingestion becomes more complex — but it's already the most complex module and the natural home for this work
* Bad, because existing domain events in the log won't have the new fields until re-ingested — `reingest!` is needed after this change
