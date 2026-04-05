# 008. OTP supervision requirements

Date: 2026-04-05

## Status

Accepted

## Context

Scry2's supervision tree contains several independent stateful processes: the `Player.log` watcher, the event ingester, the 17lands importer, and various stats/telemetry handlers. Without explicit structure, these can suffer from:

- **Stale telemetry handlers** that capture `self()` and remain registered with dead PIDs after crash-restart, so the new process's `attach_many` fails silently.
- **No explicit restart limits.** With Erlang defaults (3 restarts in 5 seconds), any cluster of flaky children can terminate the entire application.
- **Missing structural dependencies.** If ingester depends on the watcher's output buffer, a watcher crash should cascade to its dependent process — but flat `:one_for_one` doesn't encode this.
- **Lost PubSub events during restart.** Processes that subscribe in `init/1` miss events fired during the restart window.

## Decision

Encode dependencies in sub-supervisors with explicit restart limits.

1. **Every supervisor must set explicit `max_restarts` and `max_seconds`.** Never rely on Erlang defaults — the limits must be visible in code and tuned to the subsystem's expected failure rate.
2. **Processes with restart dependencies must be grouped under a sub-supervisor** with the appropriate strategy (`:rest_for_one` for sequential dependencies, `:one_for_all` for mutual dependencies).
3. **Telemetry handlers attached in `init/1` must detach stale handlers before re-attaching.** Call `:telemetry.detach/1` before `:telemetry.attach_many/4`.
4. **GenServers that subscribe to PubSub should use `handle_continue/2`** to run an immediate recovery check on restart, closing the gap where events may have been missed.
5. **The root supervisor remains `:one_for_one`** for independent subsystems. Sub-supervisors encode structural dependencies within subsystems.

## Consequences

- A crash in one subsystem no longer risks tripping the root's restart limit for unrelated children.
- Telemetry handlers survive crash-restart without manual intervention.
- The supervision tree is self-documenting — restart dependencies are visible in code.
- Processes that rely on PubSub recover missed events immediately on restart.
- Adds a small amount of structural code for sub-supervisors.
