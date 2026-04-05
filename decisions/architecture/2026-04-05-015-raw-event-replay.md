# 015. Raw event replay store

Date: 2026-04-05

## Status

Accepted

## Context

MTGA changes its log event structures between game releases. When the shape of a draft pick or a deck submission changes, downstream parsers break silently — an unknown field, a renamed key, a nested object that used to be flat. When bugs are found in the parser, we need to reprocess historical events without re-playing MTGA sessions (which is impossible — games can't be replayed).

Without a durable raw-event store, any parser bug is permanently corrupting: events that flowed through the broken version of the parser are lost, and re-running the parser on fresh input only captures new events.

## Decision

Every parsed log event is persisted to `mtga_logs_events` with its full raw JSON (in the `raw_json` column) **before** any downstream context consumes it. The `MtgaLogs` context is the sole writer; ingester processes for the `Matches`, `Drafts`, and `Cards` contexts read from this table (or subscribe to its PubSub topic), not directly from the watcher.

Reprocessing is always possible via `Scry2.MtgaLogs.reprocess/1`, which replays a range of events from the raw store back through the current parser and ingesters.

## Consequences

- Storage cost is small — a few MB per month of active play.
- Fully recoverable pipeline: any parser bug can be fixed and the full history reprocessed.
- Auditable data provenance: every derived row can be traced back to its source event.
- New event types can be added retroactively (e.g., if we decide to start tracking a field we previously ignored, old events can be re-scanned).
- This is the project's single most important data-integrity guarantee.
