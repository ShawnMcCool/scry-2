---
status: accepted
date: 2026-04-06
---
# Complete event coverage — nothing gets quietly lost

## Context and Problem Statement

MTGA's Player.log emits dozens of distinct event types. Today only two
(`MatchGameRoomStateChangedEvent` with two stateType variants) produce
domain events; every other raw type silently falls through the catch-all
`translate(%EventRecord{}, _) → []` clause. When Wizards adds a new
event type or renames an existing one, Scry2 has no way to notice — the
new data just disappears into the void.

The current `event_type` column on `mtga_logs_events` records what
arrived, but nothing compares that set against what IdentifyDomainEvents
actually handles. Unknown events produce zero domain events and zero
warnings. This is the opposite of the data-integrity guarantee that
ADR-015 (raw event replay) was designed to support.

## Decision Outcome

Chosen option: "complete event coverage with explicit discovery", because
data silently falling through a catch-all is a bug, not a feature.

### The rule

Every raw MTGA event type that appears in Player.log must have one of
two outcomes in IdentifyDomainEvents:

1. **Translated** — a `translate/2` clause produces one or more domain
   events from it.
2. **Explicitly ignored** — a `translate/2` clause matches the event
   type and returns `[]` with a comment explaining why (UI noise, lobby
   chatter, unsupported draft state, etc.).

There is no silent catch-all. If a new raw event type arrives that
doesn't match any clause, it is an **unrecognized event** and must be
surfaced to the user.

### Event discovery

The system maintains a registry of known raw event types — both
translated and explicitly ignored. When a raw event arrives whose
`event_type` is not in the registry, it is flagged as unrecognized.

Unrecognized events are:
- Visible in the admin UI via a dashboard widget showing new/unknown
  event types with sample counts and first-seen timestamps
- Logged via `Scry2.Log` so they appear in the console drawer
- Still persisted to `mtga_logs_events` with full `raw_json` (ADR-015
  guarantees nothing is lost at the raw layer)

This makes MTGA protocol changes observable: when Wizards adds, renames,
or restructures events, the user sees them immediately and can work with
Claude Code to implement the translation.

### Consequences

* Good, because no data is silently lost — every event type is either
  handled or flagged
* Good, because MTGA protocol changes become immediately visible in the
  UI, not discovered weeks later when someone notices missing data
* Good, because the discovery widget creates a natural workflow: see new
  event → inspect sample payload → decide translate vs ignore → implement
* Good, because raw events are always persisted regardless of recognition
  status, so historical data can be reprocessed when support is added
* Bad, because the registry must be maintained — adding a new translated
  or ignored event type requires updating it
* Bad, because noisy event types (ClientToGre*, periodic status polls)
  will briefly clutter the discovery widget until explicitly ignored —
  acceptable one-time cost per event type
