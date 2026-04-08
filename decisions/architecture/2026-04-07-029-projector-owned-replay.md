---
status: accepted
date: 2026-04-07
---
# Projectors own their own replay via cursor-based event queries

## Context and Problem Statement

The current `replay_projections!/0` broadcasts every domain event on PubSub and relies on all projectors receiving them in order. This has two fundamental problems:

1. **Race conditions during replay.** Events are broadcast rapidly. Multiple projectors compete for the same events. A `MatchCompleted` event can arrive at a projector before the `MatchCreated` event for the same match, causing field overwrites and data loss.

2. **No isolation.** If one projector needs rebuilding, every projector re-processes every event. There's no way to replay just the mulligans projection without also replaying matches and drafts.

The selective-field upsert (`{:replace, fields}`) was a band-aid. The real problem is that replay should not use PubSub at all — PubSub is for live streaming, not batch replay.

## Decision Outcome

Each projector is responsible for its own replay. Projectors query the domain event store directly using a cursor-based batch system, processing events sequentially in ID order.

### Rules

1. **Projectors query, not subscribe, during replay.** A projector's `rebuild!/0` function queries `domain_events` for its claimed event types, ordered by ID, in batches. It processes each batch sequentially before fetching the next. No PubSub involved.

2. **Cursor-based batching.** Each batch query uses `WHERE id > last_seen_id ORDER BY id ASC LIMIT batch_size`. This keeps memory bounded and allows progress tracking. Default batch size: 500.

3. **Each projector truncates its own tables first.** `rebuild!/0` deletes all rows in the projection table, then replays from the beginning. This is simpler and safer than incremental catch-up (which would need to handle schema changes).

4. **Projectors still subscribe to PubSub for live events.** The GenServer subscribes to `domain:events` at init for real-time updates (the current behavior). Replay is a separate code path that runs on demand.

5. **`replay_projections!/0` calls each projector's `rebuild!/0` in sequence.** Instead of broadcasting events, it calls each projector's rebuild function one at a time. Order between projectors doesn't matter because each one queries its own events independently.

6. **Selective-field upserts remain the standard.** Even with ordered replay, projectors should still only update the fields relevant to each event type. This is defense in depth — correct by construction, not just by ordering.

### Interface

```elixir
# Each projector implements:
def rebuild! do
  Repo.delete_all(MyProjectionTable)
  
  Events.stream_by_types(@claimed_slugs)
  |> Stream.chunk_every(500)
  |> Enum.each(fn batch ->
    Enum.each(batch, &project/1)
  end)
end

# The orchestrator calls each in sequence:
def replay_projections! do
  Matches.UpdateFromEvent.rebuild!()
  Drafts.UpdateFromEvent.rebuild!()
  Mulligans.UpdateFromEvent.rebuild!()
  MatchListing.UpdateFromEvent.rebuild!()
end
```

### Consequences

* Good, because replay is deterministic — events processed in strict ID order, one at a time
* Good, because projectors are isolated — rebuild one without touching others
* Good, because no PubSub race conditions during replay
* Good, because cursor-based batching keeps memory bounded for large event stores
* Neutral, because each projector needs a `rebuild!/0` function — but the pattern is mechanical
* Neutral, because `Events` needs a `stream_by_types/1` query helper — straightforward to add
