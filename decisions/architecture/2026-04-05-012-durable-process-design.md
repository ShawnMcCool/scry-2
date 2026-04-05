# 012. Durable process design

Date: 2026-04-05

## Status

Accepted

## Context

Scry2 runs stateful processes that can lose in-flight work or miss events during a crash-restart window:

- **Watcher** tails `Player.log` by byte offset. On restart, if it doesn't persist the offset, it either re-reads the entire file (wasting work) or skips events written during downtime (data loss).
- **Ingester** holds an in-memory dispatch queue for freshly parsed events. On restart, queued work is lost if there's no durable backstop.
- **Importer** (17lands CSV) may be mid-download on crash — half-written rows must not be visible as a "successful" import.
- **Stats counters** reset to zero, losing session metrics.

The shared anti-pattern is stateful processes that hold volatile in-memory queues, timers, or external resource handles with no strategy for restart recovery.

## Decision

Every stateful process must be designed for restart durability. Each process must satisfy one of two properties:

- **Resumable:** persists enough durable state (e.g., the watcher's byte offset in `mtga_logs_watcher_state`) that restart picks up exactly where it left off.
- **Idempotent restart:** re-derives its state from durable sources (SQLite, filesystem, config) such that restarting from scratch produces the same eventual outcome as if it never stopped.

**Requirements:**

1. **In-memory queues must have a durable backstop.** Any process holding a queue of work items must be able to re-derive that queue from durable state (DB query, filesystem scan) on restart. The queue is a performance optimization, not the source of truth. This is why `mtga_logs_events` exists (see ADR-015).
2. **Startup must reconcile.** Processes that watch for real-time events (file tailing, PubSub) must perform a reconciliation pass on startup via `handle_continue/2` to detect anything that changed while they were down.
3. **Debounce buffers must flush on shutdown.** Any process holding a buffer of deferred work must flush synchronously in `terminate/2` rather than silently dropping the buffer. This requires `trap_exit`.
4. **External downloads must be atomic.** Multi-step imports (e.g., 17lands CSV ingestion) must write to a staging table or temp file and swap on success — never leave partial state visible.

## Consequences

- Restart-related data loss becomes a design defect with a clear fix pattern, not an accepted risk.
- Builds naturally on the raw-event replay store (ADR-015) and idempotent ingestion (ADR-016).
- Startup reconciliation adds a small amount of latency to process init (mitigated by running in `handle_continue/2`).
- `terminate/2` flush requires `trap_exit`, adding small boilerplate to affected processes.
