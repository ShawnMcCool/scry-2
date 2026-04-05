# 009. GenServer API encapsulation

Date: 2026-04-05

## Status

Accepted

## Context

Several GenServers in Scry2 (`Scry2.MtgaLogs.Watcher`, `Scry2.MtgaLogs.Ingester`, `Scry2.Config`) are called from multiple modules. When callers use `GenServer.call/2` or `GenServer.cast/2` directly, the message protocol leaks across module boundaries. This couples callers to the message format, the registered name, and the fact that the module is a GenServer at all. Refactoring the process — renaming it, splitting it into two, or replacing it with ETS — requires updating every call site.

## Decision

Wrap all GenServer interactions in public functions on the owning module.

1. **Never call `GenServer.call/2` or `GenServer.cast/2` from outside the module** that defines the GenServer.
2. **Expose a public function API** on the module that wraps the call or cast internally.
3. **Callers use the module's public functions**, not the GenServer protocol directly.

## Consequences

- The GenServer's message format is an internal implementation detail.
- The process can be refactored (renamed, split, replaced with ETS) without changing callers.
- The public API can validate arguments and provide documentation.
- Each GenServer needs thin wrapper functions that may feel like boilerplate.
