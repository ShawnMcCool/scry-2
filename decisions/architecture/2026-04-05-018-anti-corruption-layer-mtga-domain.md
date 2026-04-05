---
status: accepted
date: 2026-04-05
---
# Anti-corruption layer between MTGA wire format and scry_2 domain

## Context and Problem Statement

MTGA's Player.log format is an external, unstable contract. Wizards
can (and will) rearrange fields, add nesting, rename event types, or
change wire formats between client releases. A scry_2 codebase that
leaks MTGA vocabulary into its domain logic would be forced to chase
every MTGA change across many files.

Before this decision, the `Scry2.Matches.EventMapper` module used MTGA
event type names (`MatchGameRoomStateChangedEvent`) in its function
names and decoded nested MTGA JSON paths directly into attrs maps that
were then written to Ecto schemas. Multiple bounded contexts would
eventually each grow their own mapper with similar leakage — every
consumer would duplicate the raw-JSON → domain translation.

Domain-Driven Design calls this the Anti-Corruption Layer pattern: a
single module that knows both sides and translates between them. The
internal domain never sees the external form.

ADR-017 establishes event sourcing as the core architecture. This ADR
names the specific translation layer and its contracts.

## Decision Outcome

Chosen option: **`Scry2.Events.Translator` is the ONLY module in scry_2
that understands MTGA's wire format**, because a single translation
point is easier to maintain, audit, and update when MTGA changes.

### The rule

MTGA event type names, nested MTGA JSON paths, and MTGA-specific
vocabulary (`matchGameRoomStateChangedEvent`, `gameRoomInfo`,
`MatchGameRoomStateType_Playing`, etc.) appear in exactly one file:
`lib/scry_2/events/translator.ex`. Every other module in scry_2 works
with typed domain event structs (`%Scry2.Events.MatchCreated{}`, etc.)
and the `Scry2.Events.Event` protocol.

Test: grep the codebase for `matchGameRoomStateChangedEvent`. If it
appears outside `translator.ex` or `translator_test.exs`, that's a
leak and a bug.

### What the Translator does

Pure function module. Takes a `%Scry2.MtgaLogs.EventRecord{}` (which
carries raw MTGA JSON) plus `self_user_id` for distinguishing self
from opponent in `reservedPlayers[]`. Returns a list of domain event
structs — zero, one, or many, depending on what the raw event means
in our domain.

Function head pattern matching dispatches on the raw MTGA event type.
Each clause decodes the payload, extracts the relevant fields, and
builds domain event structs. A single MTGA event can produce multiple
domain events (e.g. a `GreToClientEvent` carrying a `connectResp` AND
a `GameStateMessage` could produce both a `%DeckSubmitted{}` and a
`%GameStateChanged{}`).

### Naming convention

* **MTGA event type names** — used only inside `translator.ex` and
  `mtga_logs_events.event_type`. Examples: `"MatchGameRoomStateChangedEvent"`,
  `"GreToClientEvent"`, `"EventJoin"`.
* **Domain event slugs** — stable snake_case identifiers for the
  `domain_events.event_type` column. Owned by scry_2. Examples:
  `"match_created"`, `"match_completed"`, `"deck_submitted"`.
* **Domain event struct modules** — PascalCase under `Scry2.Events.*`.
  Examples: `Scry2.Events.MatchCreated`, `Scry2.Events.MatchCompleted`.

A single MTGA event type may map to multiple domain events (a
`MatchGameRoomStateChangedEvent` with `stateType: Playing` becomes
`%MatchCreated{}`; with `stateType: MatchCompleted` becomes
`%MatchCompleted{}`). Domain event names reflect **what happened in
our domain**, not **which MTGA event carried it**.

### How to add a new domain event

1. Create `lib/scry_2/events/<name>.ex` with `defstruct`,
   `@enforce_keys`, `@type t :: ...`, and `defimpl Scry2.Events.Event`.
2. Add a `translate/2` clause in `Scry2.Events.Translator` that
   consumes the relevant raw MTGA event type and produces the struct.
3. Add a rehydration clause in `Scry2.Events.get/1` for the new slug.
4. Add a projector handler in whichever context owns the projection
   (if any — real-time consumers don't need projections).
5. Add tests: struct test, translator clause test using a real fixture
   (per ADR-010), projector handler test if applicable.
6. Commit the fixture to `test/fixtures/mtga_logs/` so the translator
   change is regression-tested on real data.

## Consequences

* **Good:** MTGA protocol changes are localized to one file. Domain
  logic and UI code stay stable across MTGA updates.
* **Good:** Domain events are the public contract. New consumers
  subscribe to `domain:events` and work with typed structs — they
  never see raw JSON, never know about MTGA's nesting.
* **Good:** Testing is cleaner. Translator tests use real MTGA fixtures
  (ADR-010); everything downstream uses struct literals.
* **Good:** Refactoring the translator is a local operation. Changes
  to MTGA wire format rarely touch anything else.
* **Bad:** One more layer of indirection. A reader tracing "how does
  a match row get created from Player.log?" has to walk through the
  Translator instead of jumping directly from the ingester to the
  upsert.
* **Bad:** The rehydration dispatch in `Scry2.Events.get/1` must stay
  in sync with the struct modules. Adding a new event type requires
  touching both. Mitigated: both live under `lib/scry_2/events/` and
  are small, focused files.
* **Bad:** The translator can grow large as more event types are
  supported. If it becomes unwieldy, split into submodules (e.g.
  `Translator.MatchEvents`, `Translator.DraftEvents`) while keeping
  the single public `translate/2` entry point.

### Relationship to other ADRs

* **ADR-015 (raw event replay)** — the translator reads from the raw
  event store. If the translator has bugs, raw events can be
  re-translated via `Scry2.Events.retranslate_from_raw!/0`.
* **ADR-017 (event sourcing)** — the translator feeds the domain event
  log. This ADR is the "how"; ADR-017 is the "why".
* **ADR-010 (append-only parser tests)** — translator tests use real
  fixtures from `test/fixtures/mtga_logs/`, same discipline as parser
  tests. Every new event type ships with its fixture.
