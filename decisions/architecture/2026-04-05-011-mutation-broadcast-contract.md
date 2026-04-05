# 011. Mutation broadcast contract

Date: 2026-04-05

## Status

Accepted

## Context

The Scry2 admin LiveView needs to stay in sync with database changes in real time. When matches, drafts, or cards are created, updated, or destroyed, subscribers must receive the updated state. Without a consistent broadcast contract, some mutations could silently fail to notify the UI, leaving it stale.

## Decision

Every context that owns mutable data exposes a PubSub topic through `Scry2.Topics`. Every operation that creates, updates, or destroys records in that context broadcasts a uniform change event on that topic.

**Contract rules:**
- Each context has a single "updates" topic (`matches:updates`, `drafts:updates`, `cards:updates`).
- Mutations broadcast a tuple like `{:matches_changed, match_ids}` — a list of affected IDs, not separate create/update/delete events.
- IDs must be collected before deletion (they are gone afterward).
- Subscribers (LiveViews) resolve IDs into updated/removed sets by querying current state — the broadcaster does not distinguish create from update from delete.
- Bulk operations must check their result counts — silent failures stall the UI.

## Consequences

- One event type per context handles all mutation kinds — no separate create/update/destroy events to maintain.
- Subscribers own the resolution logic — they query current state and determine what changed.
- Broadcasting IDs without distinguishing mutation type means subscribers must always query the database to determine what happened.
