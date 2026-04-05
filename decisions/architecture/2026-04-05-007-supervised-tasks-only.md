# 007. Always use Task.Supervisor for async work

Date: 2026-04-05

## Status

Accepted

## Context

Fire-and-forget async work is tempting to dispatch with bare `Task.start/1`. Unsupervised tasks are invisible to the supervision tree — if they crash, no one notices, and they cannot be monitored or shut down gracefully during application stop. In Scry2, background work includes 17lands CSV downloads, Scryfall backfills, and deferred upserts triggered by log events — all of which must be visible if they fail.

## Decision

Always use `Task.Supervisor.start_child(Scry2.TaskSupervisor, ...)` for async work. Never use bare `Task.start/1` or `Task.async/1` for fire-and-forget work.

## Consequences

- All async work is visible in the supervision tree and crashes are logged.
- `Task.Supervisor` respects application shutdown ordering.
- Slightly more verbose than bare `Task.start` — an acceptable trade-off.
