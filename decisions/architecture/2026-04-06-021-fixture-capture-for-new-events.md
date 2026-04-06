---
status: accepted
date: 2026-04-06
---
# Capture anonymized fixtures for every new event type

## Context and Problem Statement

When a new MTGA event type is observed — either via the discovery widget
(ADR-020) or while mining Player.log for specific data — the raw JSON
payload is the single most valuable artifact for building and testing
the translator clause. Without a real fixture, development stalls or
relies on guesswork about the wire format.

ADR-010 (regression tests append-only) already requires real fixtures
for parser tests. This decision extends that principle to every stage
of the ingestion pipeline: parser, translator, and projector tests all
use real captured data.

## Decision Outcome

Chosen option: "always capture and commit an anonymized fixture when a
new event type is encountered", because real data eliminates guesswork
and fixtures are cheap to store.

### The rule

Whenever a new raw MTGA event type is observed — whether it will be
translated into a domain event, explicitly ignored, or is still under
investigation — capture a real sample and commit it as a fixture:

1. **Extract** the raw event from `mtga_logs_events.raw_json` (or
   directly from Player.log).
2. **Anonymize** opponent PII: replace opponent `playerName` with
   `Opponent1`, `Opponent2`, etc. Replace opponent Wizards `userId`
   with `OPPONENT_USER_ID_1`, etc. The user's own values stay (this
   is a single-user personal repo).
3. **Save** to `test/fixtures/mtga_logs/<event_type_snake_case>.log`
   including the `[UnityCrossThreadLogger]` header line so the parser
   can extract the event type and timestamp.
4. **Commit** the fixture alongside the translator clause or ignore
   clause that handles it.

### Naming convention

Fixture files use snake_case of the MTGA event type, optionally with
a suffix for variants:

- `match_game_room_state_changed_playing.log`
- `match_game_room_state_changed_completed.log`
- `gre_to_client_event_connect_resp.log`
- `gre_to_client_event_game_complete.log`
- `authenticate_response.log`

### Consequences

* Good, because every translator clause is backed by real data from
  the actual MTGA client — no synthetic payloads, no guessing field
  names
* Good, because fixtures serve as living documentation of MTGA's wire
  format at a point in time
* Good, because when MTGA changes its format, the fixture diffs show
  exactly what changed
* Good, because anonymization is a one-time manual step per fixture,
  not an ongoing burden
* Bad, because fixtures can be large (GRE messages are 10-50KB) —
  acceptable for a personal repo with a small fixture set
