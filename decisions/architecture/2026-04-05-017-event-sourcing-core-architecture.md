---
status: accepted
date: 2026-04-05
---
# Event sourcing as the core architecture for MTGA ingestion

## Context and Problem Statement

Scry2 ingests MTGA Player.log events and turns them into queryable state
(matches, games, drafts, etc.) for dashboards, analytics, and real-time
consumers. The original design wrote directly from a mapper function
into Ecto upserts — raw JSON → flat attrs → DB row. That worked for a
thin slice but had structural problems for the app's ambitions:

* **Multiple consumers.** The user intends to build several real-time
  tools and analyses that react to MTGA activity. Under the direct-upsert
  design, each new consumer would have to re-parse raw MTGA JSON.
* **No typed intermediate form.** Passing decoded-JSON maps around
  means no compile-time checks on field names, no documentation, and
  no grep-ability for "where do we use MatchCreated semantics?".
* **Translation fused with persistence.** A single function both
  understood MTGA's wire format AND built DB schema attrs. Any change
  to either side required changes to both.
* **No rebuild path.** If a projection table's contents became
  corrupted or a new projection was added, rebuilding required re-parsing
  the raw log — slow, and the raw log might not contain everything
  (e.g. aggregated domain concepts like "deck submitted" that combine
  multiple raw events).
* **ADR-015 covers raw events** (Player.log bytes preserved for replay)
  but not *domain* history — there was no canonical log of "what
  actually happened in the user's MTGA domain" separate from MTGA's
  wire format.

The app will live a long time and grow many features. The cost of
fixing this architecture now is low (~200 lines); the cost of fixing
it after ten mappers have accreted would be ten times that.

## Decision Outcome

Chosen option: **event sourcing with an append-only domain event log
and projection-based read models**, because it cleanly separates what
happened from what we store, supports multiple consumers without
re-translation, and makes rebuild trivial.

### The architecture

1. **Raw event log** (`mtga_logs_events`) — unchanged from ADR-015.
   Every parsed MTGA event is persisted verbatim. This is the ultimate
   ground truth and is never mutated.

2. **Domain event log** (`domain_events`) — NEW. Append-only table
   storing typed domain events produced by IdentifyDomainEvents from raw
   events. Every row has a stable `event_type` slug (`"match_created"`,
   `"match_completed"`, etc.) and a JSON payload that rehydrates into a
   struct under `Scry2.Events.*`. See ADR-018 for the translator.

3. **Projections** (`matches_matches`, `matches_games`,
   `matches_deck_submissions`, `drafts_drafts`, `drafts_picks`) — derived
   state. Updated by projectors (GenServers in each bounded context)
   that subscribe to the `domain:events` PubSub topic. Projection tables
   can be dropped and rebuilt at any time by replaying domain events.

4. **Distribution** — downstream consumers (projectors, LiveViews,
   analytics, future overlays) subscribe to `domain:events` via PubSub.
   None of them touch `mtga_logs_events` or IdentifyDomainEvents directly.
   The anti-corruption boundary (ADR-018) is enforced at the PubSub
   topic.

### Rebuild semantics

Two rebuild modes:

* **`Scry2.Events.replay_projections!/0`** — drops projection rows,
  iterates `domain_events` in id order, re-broadcasts each. Used when
  a projector's logic changes or a new projection is added. The domain
  event log is the source of truth; nothing is re-translated.

* **`Scry2.Events.retranslate_from_raw!/0`** — truncates `domain_events`,
  resets the `processed` flag on raw events, lets the
  `Scry2.Events.IngestRawEvents` re-translate from scratch. Used when
  IdentifyDomainEvents' logic changes. The raw log (ADR-015) is the source
  of truth; domain events are regenerated.

Both modes are deterministic because projectors are idempotent by
construction — they use upsert-by-MTGA-id (ADR-016).

### Why not just direct writes with typed DTOs?

A lighter option would be to introduce typed domain event structs but
*not* persist them — just broadcast and write directly to projection
tables. That gives most of the decoupling benefits at lower cost.

Rejected because:

* **Rebuild requires re-translation.** If a projection is lost or a new
  one is added, you have to re-read all raw events through the current
  translator. Every translator bug or update forces this path. With a
  persistent domain event log, projections can be rebuilt without
  touching the translator.
* **Domain events aggregate over raw events.** A single `%DeckSubmitted{}`
  might come from a specific `GreToClientEvent.connectResp.deckMessage`
  nested 5 levels deep inside a raw event. Persisting the aggregated
  domain form means consumers don't need to know the raw aggregation
  rules.
* **User's directive: best design only.** For a long-lived app, the
  cost of persistence is small and the flexibility is permanent.

## Consequences

* **Good:** Clear separation of concerns (capture → translate → persist
  → project → display). Each layer has a narrow contract.
* **Good:** Multiple consumers can subscribe to `domain:events` without
  re-implementing raw JSON parsing. Adding a new analysis, an overlay,
  or an export tool is "subscribe + pattern-match on the struct".
* **Good:** Projections are disposable. If schema evolves, drop and
  rebuild from the event log.
* **Good:** Historical data stays valid across code changes. Old domain
  events rehydrate into the current struct shape (with missing fields
  becoming nil).
* **Good:** Strong debugging story — every domain event has a
  `mtga_source_id` pointing at the raw event that produced it.
* **Bad:** Two persistence layers (raw log + domain log) instead of one.
  Slightly more disk space and more moving parts.
* **Bad:** Rehydration dispatch (`Scry2.Events.get!/1`) is a case
  statement on slug — must be updated when a new event type is added.
  Acceptable — it's a single choke point and the pattern is mechanical.
* **Bad:** More files. The `lib/scry_2/events/` directory has one
  module per event type. Mitigated by the self-documenting pipeline
  principle — each file is small and focused.

### Relationship to other ADRs

* **ADR-015 (raw event replay)** — still the ultimate truth. Domain
  events are derived; raw events are inviolate.
* **ADR-016 (idempotent log ingestion)** — projectors are idempotent by
  construction; replay is safe.
* **ADR-011 (mutation broadcast contract)** — projection contexts still
  broadcast `matches:updates` / `drafts:updates` after projection writes;
  that's unchanged. The `domain:events` topic is an additional layer
  *above* those, not a replacement.
* **ADR-018 (anti-corruption layer)** — IdentifyDomainEvents is the
  single place MTGA's wire format is understood; see that ADR for details.
