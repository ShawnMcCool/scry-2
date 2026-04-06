# 006. Bounded contexts communicating through PubSub

Date: 2026-04-05

## Status

Accepted

## Context

Scry2 has multiple functional areas — log watching, event parsing, match and draft ingestion, card reference data, and the web layer. Without clear boundaries, these areas would tend to reach into each other's internals, creating tight coupling where a change in one subsystem requires understanding and modifying several others.

## Decision

Adopt bounded contexts with PubSub-only cross-context communication. Each context owns its own data and behavior; cross-context interaction happens exclusively through `Phoenix.PubSub` broadcasts, routed through `Scry2.Topics` helpers.

**Context boundaries:**
- `Scry2.MtgaLogIngestion` — raw log events, file-watch state, parser cursor
- `Scry2.Events` — domain event log, anti-corruption layer
- `Scry2.Matches` — matches, games, deck submissions (projection)
- `Scry2.Drafts` — drafts, draft picks (projection)
- `Scry2.Cards` — cards and sets (from 17lands + Scryfall)
- `Scry2.Settings` — runtime config entries
- `Scry2Web` — LiveViews, components, router

**Communication rules:**
- Contexts never call into another context's internal modules.
- All cross-context interaction uses `Phoenix.PubSub` broadcasts via `Scry2.Topics`.
- Consumers (LiveViews, Oban workers) may read any context's public API freely — they are not bounded contexts.

## Consequences

- Modifying one context does not require analyzing blast radius on unrelated contexts.
- PubSub events create a clear, auditable integration surface.
- Contexts can be tested in isolation with PubSub stubs.
- PubSub events are fire-and-forget — debugging cross-context flows requires correlating events across subscribers.
