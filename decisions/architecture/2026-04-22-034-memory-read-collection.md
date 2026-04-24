---
status: accepted
date: 2026-04-22
---
# 034. Memory-read card collection via Rust NIF + Scry2.Collection context

## Status

Accepted (revised 2026-04-25 — see [Revision 2026-04-25](#revision-2026-04-25--walker-in-rust))

## Context and Problem Statement

MTGA stopped writing the full `PlayerInventory.GetPlayerCardsV3` payload
to `Player.log` in the 2021.8.0.3855 client update. Every log-parsing
tracker — including scry_2 — has been collection-blind since. The
mechanism survey in the companion research repo
([`mtga-duress/research/001-mtga-collection-acquisition.md`](../../../mtga-duress/research/001-mtga-collection-acquisition.md))
narrowed viable acquisition to three paths: manual CSV import, derivation
from existing domain events (lower-bound only), and **reading the
collection directly from MTGA's process memory**.

The design research
([`mtga-duress/research/002-mtga-memory-reader-design.md`](../../../mtga-duress/research/002-mtga-memory-reader-design.md))
proves the memory-read path end-to-end on Linux: a Rust POC extracts
4,091 cards in ~1.4 s from a live MTGA; a pure-Elixir port extracts the
same 4,091 cards in ~3.7 s. Follow-up analysis
([`mtga-duress/experiments/notes/`](../../../mtga-duress/experiments/notes/))
established that Windows needs a native helper (no `/proc/<pid>/mem`),
that a **thin Rustler NIF** is the cleanest cross-platform bridge, and
that memory-sourced snapshots coexist with log-sourced events via CQRS
(snapshots on the read side; domain events untouched on the write side).

This ADR commits scry_2 to that design and lays out the implementation.

## Decision Drivers

- **Complete collection coverage.** No other mechanism short of manual
  CSV import gives us the full arena_id → count map on post-2021 MTGA.
- **Single stack.** scry_2 has adopted "one language for logic" as a
  design value. The implementation must keep 95% of logic in Elixir and
  the cross-language surface minimal.
- **Cross-platform at parity.** Linux, Windows, and macOS must all be
  supported by the same code path, even if only Linux + Windows can be
  tested today.
- **Loud failure mode.** Per CLAUDE.md's data-integrity section: never
  silently produce stale or wrong data. The reader self-checks and
  refuses output if it can't prove its own correctness.
- **Kill-switchable.** If WotC's ToS enforcement posture changes, a
  single release removes the feature without touching the rest of scry_2.
- **Source-only distribution of the sensitive surface.** User must
  explicitly opt in via a disclosure modal; the feature is off by
  default.

## Considered Options

The mechanism choice (Avenue 5 of `001-*`) and the Rust-vs-Elixir +
walker-vs-scan choices are all pre-settled by the research. The
residual implementation-level choice is how Rust and Elixir cross the
boundary:

| Pattern | Result |
|---|---|
| **Thin Rustler NIF** (three primitives, Elixir above) | **chosen** |
| Fat Rustler NIF (walker in Rust) | rejected — duplicates ~1,500 lines across languages |
| Port sidecar (Rust binary, JSON over stdin/stdout) | rejected — adds IPC latency, cross-language contract surface |
| Long-lived Rust daemon (UDS protocol) | rejected — same as Port sidecar plus daemon lifecycle complexity |

See [`mtga-duress/experiments/notes/rust-integration.md`](../../../mtga-duress/experiments/notes/rust-integration.md)
for the full trade-off analysis.

## Decision Outcome

**Chosen**: introduce a thin Rustler NIF that exposes three memory
primitives — read bytes, list memory mappings, find a process by
predicate — and build the entire walker, scanner, and fallback logic in
Elixir, dispatched from a new `Scry2.Collection` bounded context.

> **Revised 2026-04-25:** the walker has been moved into the Rust crate.
> The NIF now exposes memory primitives *plus* a `walk_collection`
> function that performs the full pointer-chain walk internally and
> returns a decoded result map. Elixir retains orchestration, self-check,
> fallback-to-scanner, and all read-side integration. The structural
> scanner remains in Elixir. See [Revision 2026-04-25](#revision-2026-04-25--walker-in-rust).

### Architecture summary

```
┌─────────────────────────────────────────────────────────────────┐
│  Scry2.Collection (bounded context)                             │
│                                                                 │
│    Collection.current/0 ─── reads snapshot, falls back to       │
│                             log-derived lower-bound              │
│    Collection.refresh/0 ─── enqueues RefreshJob                 │
│                                                                 │
│    ┌────────────────────────────────────────────────────┐       │
│    │  Reader (Elixir orchestration)                     │       │
│    │    - find MTGA, list maps                          │       │
│    │    - invoke Rust walker (primary)                  │       │
│    │    - structural scan in Elixir (fallback)          │       │
│    │    - self-check gate (Spike 13's 7 checks)         │       │
│    └────────┬───────────────────────────────────────────┘       │
│             │ behaviour: primitives + walk_collection           │
│    ┌────────▼──────────┐      ┌────────────────────────┐        │
│    │  Mem.Nif (prod)   │      │  Mem.TestBackend (test)│        │
│    │  via Rustler      │      │  in-memory fixture     │        │
│    │  - primitives     │      │  (primitives only —    │        │
│    │  - walk_collection│      │   walker tested in     │        │
│    │                   │      │   Rust w/ byte fixt.)  │        │
│    └────────┬──────────┘      └────────────────────────┘        │
└─────────────┼───────────────────────────────────────────────────┘
              │
   native/scry2_collection_reader/
   (Rust crate, ~100 lines, platform dispatch inside)
```

### Consequences

- **Good**: complete collection; single-stack Elixir logic; minimal
  cross-language contract (three function signatures); fits existing
  release/MSI packaging with no new distribution patterns.
- **Good**: walker + scan dual-path reader (per Spike 13) gives defense
  in depth; loud-failure mode preserves data integrity.
- **Bad**: introduces Rust toolchain to scry_2's dev and CI environments.
- **Bad**: NIF panics would crash the BEAM VM; mitigated by
  panic-free construction and lint enforcement.
- **Bad**: ToS grey-zone feature; ships off by default with explicit
  informed-consent modal; kill switch via release-level removal.

## Detailed Design

### Bounded context: `Scry2.Collection`

Owns tables: `collection_snapshots`. Subscribes: none (reads `mtga_logs`
schema only for divergence checks). Broadcasts: `collection:snapshots`.

Public API:

```elixir
# Read-side
Scry2.Collection.current()               :: Snapshot.t() | nil
Scry2.Collection.list_snapshots(opts)    :: [Snapshot.t()]
Scry2.Collection.reader_enabled?()       :: boolean

# Write-side
Scry2.Collection.refresh(opts)           :: {:ok, %Oban.Job{}}
Scry2.Collection.enable_reader!()        :: :ok
Scry2.Collection.disable_reader!()       :: :ok

# Diagnostics
Scry2.Collection.last_error()            :: %{check: atom, observed: term} | nil
Scry2.Collection.divergence_vs_log()     :: %{missing_from_log: [integer], extra_in_log: [integer]}
```

### Mem behaviour and backends

```elixir
defmodule Scry2.Collection.Mem do
  @callback read_bytes(pid :: integer, addr :: non_neg_integer, size :: non_neg_integer) ::
    {:ok, binary} | {:error, atom}

  @callback list_maps(pid :: integer) :: {:ok, [map_entry]} | {:error, atom}

  @callback find_process((%{...} -> boolean)) :: {:ok, integer} | {:error, atom}
end
```

Two implementations:

- **`Scry2.Collection.Mem.Nif`** — Rustler NIF, production. Dispatches
  to `process_vm_readv(2)` on Linux, `ReadProcessMemory` on Windows,
  `task_for_pid` + `mach_vm_read_overwrite` on macOS. The macOS branch
  ships stubbed with `{:error, :not_implemented_yet}` until we can
  test; the Rust compiles, just doesn't execute anything on macOS.
- **`Scry2.Collection.Mem.TestBackend`** — in-memory; takes a fixture
  map of `{addr => bytes}` at setup. Used by the walker/scanner test
  suite.

Runtime dispatch through Application config:

```elixir
# config/config.exs
config :scry_2, Scry2.Collection, mem: Scry2.Collection.Mem.Nif

# config/test.exs
config :scry_2, Scry2.Collection, mem: Scry2.Collection.Mem.TestBackend
```

### Rust crate

Lives in-repo at `native/scry2_collection_reader/`:

```
native/scry2_collection_reader/
├── Cargo.toml
├── src/
│   ├── lib.rs          # rustler::init!, NIF surface
│   ├── linux.rs        # #[cfg(target_os = "linux")] impls
│   ├── windows.rs      # #[cfg(target_os = "windows")] impls
│   ├── macos.rs        # #[cfg(target_os = "macos")] stubs
│   └── common.rs       # shared types (MapEntry, ProcessInfo)
└── .cargo/config.toml  # target-specific flags if needed
```

Dependencies:

- `rustler = "0.32"` (or latest stable)
- `libc = "0.2"` for Linux syscalls
- `windows-sys = { version = "0.52", features = ["Win32_System_Diagnostics_Debug", "Win32_System_Threading", "Win32_System_ProcessStatus"] }` for Windows

All NIFs run on `DirtyIo` scheduler (blocking syscalls).

Panic-free construction enforced by:

```rust
#![deny(clippy::panic, clippy::unwrap_used, clippy::expect_used)]
```

### Storage: `collection_snapshots` table

Migration shape (derived from Spike 14):

```elixir
create table(:collection_snapshots) do
  add :snapshot_ts, :utc_datetime_usec, null: false
  add :reader_version, :string, null: false
  add :reader_confidence, :string, null: false  # "walker" | "fallback_scan"
  add :mtga_build_hint, :string                 # boot.config build-guid if we can read it
  add :card_count, :integer, null: false
  add :total_copies, :integer, null: false
  add :cards_json, :text, null: false           # JSON array [{arena_id, count}, ...]
  add :wildcards_common, :integer
  add :wildcards_uncommon, :integer
  add :wildcards_rare, :integer
  add :wildcards_mythic, :integer
  add :gold, :integer
  add :gems, :integer
  add :vault_progress, :integer

  timestamps(type: :utc_datetime_usec)
end

create index(:collection_snapshots, [:snapshot_ts])
```

Append-only. Retention policy deferred to a follow-up ADR (prune-to-daily
beyond 30 days probably).

### Refresh model

`Scry2.Collection.RefreshJob` (Oban worker, queue `:collection`):

```elixir
use Oban.Worker, queue: :collection, max_attempts: 3,
    unique: [period: 30, fields: [:worker]]
```

Triggers:

- User-initiated: LiveView "Refresh now" button enqueues `args: %{"trigger" => "manual"}`.
- Scene-triggered (v2): subscribe to `mtga_logs:status`; on scene
  transition to `Wrapper`, enqueue with `args: %{"trigger" => "scene"}`.
- Startup: if reader enabled and MTGA running, do an initial refresh.

**No GenServer.** State lives in Oban job rows + the snapshot table.
Per Iron Law: no runtime reason for a dedicated process; Oban provides
serialisation via the queue.

### Feature flag

`Scry2.Settings.Entry` key `collection.reader_enabled`
(values: `"true"` | `"false"`). Default off. The informed-consent
modal writes `"true"` when the user confirms.

### LiveView surface

`Scry2WebLive.CollectionLive` (new) at `/collection`:

- "Reader disabled" banner with **Enable** button that opens the
  consent modal (Spike 15's disclosure copy).
- Current snapshot card: card count, total copies, last refresh time,
  reader confidence ("walker" / "fallback_scan"), wildcard/gold/gems
  grid.
- Cards grid filtered from `collection_snapshots.cards_json` joined
  with `cards_cards`.
- Divergence banner when `Collection.divergence_vs_log/0` shows
  unexpected mismatch.

### Self-check gate

Implemented in `Scry2.Collection.Reader` before emitting output:

```elixir
defp self_check(state) do
  with {:ok, pid} <- find_mtga(),
       {:ok, :mz} <- verify_pe_header(pid),
       {:ok, :mov_prologue} <- verify_mono_prologue(pid),
       {:ok, root} <- resolve_root_domain(pid),
       {:ok, papa} <- find_class(root, "PAPA"),
       {:ok, cards} <- walk_to_cards(papa),
       {:ok, count} <- verify_dict_size(cards),
       {:ok, dist} <- verify_plausible_distribution(cards) do
    {:ok, state}
  end
end
```

Any failure returns a tagged error routed to the LiveView console
drawer and attached to the last snapshot row (as a `last_error` record,
not a polluted `collection_snapshots` entry).

## Implementation Plan

### Test strategy

- **Existing factory functions to use**: `Scry2.TestFactory.create_card`
  (for cross-reference with `cards_cards`), `create_watched_file` (not
  directly relevant, cited for pattern).
- **New factory functions needed**: `build_collection_snapshot/1`
  (plain struct, no DB), `create_collection_snapshot/1` (persisted).
- **Test types**:
  - Pure-function tests (`async: true`) for walker, scanner, Dict
    iteration, self-check gate. Stub Mem via `Scry2.Collection.Mem.TestBackend`.
  - Resource tests (`DataCase`) for Snapshot schema, `Collection.current/0`,
    `list_snapshots/1`, `divergence_vs_log/0`.
  - Channel/LiveView tests for the view at `/collection`.
  - Integration test (manual, `@tag :external`): `Mem.Nif.read_bytes/3`
    against the BEAM process's own memory at a known address;
    verifies NIF loading and round-trip. Excluded from default `mix test`.
- **Key assertions**:
  - Walker produces same structure as POC on a known memory fixture.
  - Scanner finds all valid runs of ≥ 2000 entries given a fixture.
  - Self-check gate refuses output when any of the 7 checks fail.
  - Snapshot persistence round-trips card_count / total_copies /
    cards_json.
  - `Collection.current/0` returns snapshot when fresh, nil when absent,
    and surfaces `reader_confidence` correctly.
  - NIF returns valid binary on success, `{:error, atom}` on failure
    (never panics).

### Order of changes

**Phase 1 — infrastructure (no behavioural change)**

1. Add `rustler` dep to `mix.exs`; add `{:ex_doc, ...}` references in
   `mix.exs` if needed for NIF documentation.
2. Add Rust toolchain entry to `.mise.toml` (or equivalent): `rust =
   "1.95.0"` (current stable at time of ADR) so developers run
   `mise install` and get a consistent toolchain. Pin advances to the
   newest practical stable at implementation time; treat 1.95.0 as the
   floor, not the lock.
3. Create `native/scry2_collection_reader/` with minimal `Cargo.toml` +
   `src/lib.rs` containing a stub `ping/0` NIF returning `:pong`.
4. Verify `mix compile` builds the NIF; NIF loads in `iex`.
5. Update `.gitignore`: `/native/**/target/`.

**Phase 2 — Mem behaviour + test backend (test-first)**

6. Write failing tests in `test/scry_2/collection/reader_test.exs` that
   exercise a toy reader using `Scry2.Collection.Mem.TestBackend` with
   a hand-crafted fixture containing a valid Dictionary<int,int> entries
   array.
7. Create `Scry2.Collection.Mem` behaviour.
8. Create `Scry2.Collection.Mem.TestBackend` (pure Elixir, map-backed).
9. Tests go green for fixture-based walker exercises.

**Phase 3 — Elixir reader (test-first)**

10. Write tests covering:
    - PE export table parsing on a known binary fixture
    - Mono prologue detection (`48 8b 05 … c3` pattern)
    - MonoDomain → assemblies walk (with synthesized memory)
    - Class lookup by name (via `<Name>k__BackingField` fallback)
    - Dictionary iteration
    - Structural scan with run detection
    - Self-check gate success + failure paths
11. Implement `Scry2.Collection.Reader` to pass those tests. Offset
    tables for Unity-mono-2022.3.x embedded as module attributes; fail
    loudly on unexpected prologue.

**Phase 4 — Rust NIF (test-first at the boundary)**

12. Write `test/scry_2/collection/mem/nif_test.exs` with `@tag :external`
    (excluded by default). Tests: `read_bytes(self, addr, 16)` against
    the current BEAM's own image; validate signature.
13. Implement `src/linux.rs` with `process_vm_readv` binding,
    `list_maps` via `/proc/<pid>/maps`, `find_process` via `/proc`
    iteration.
14. Verify NIF test passes on Linux.
15. Implement `src/windows.rs` with `OpenProcess` + `ReadProcessMemory`,
    `VirtualQueryEx` for maps, `CreateToolhelp32Snapshot` for process
    enumeration.
16. Implement `src/macos.rs` returning `Err(Error::Term("not_implemented"))`
    for all three calls. Add `@tag :macos_pending` on tests.
17. Wire `Scry2.Collection.Mem.Nif` as the production backend.

**Phase 5 — snapshot storage (test-first)**

18. Write failing tests for `Snapshot` schema changeset validations.
19. Generate migration `priv/repo/migrations/<TS>_create_collection_snapshots.exs`.
20. Create `Scry2.Collection.Snapshot` schema module.
21. Add `build_collection_snapshot/1` and `create_collection_snapshot/1`
    to `Scry2.TestFactory`.

**Phase 6 — context API and Oban worker (test-first)**

22. Write tests for `Scry2.Collection.current/0`, `list_snapshots/1`,
    `refresh/1`, `reader_enabled?/0`, `enable_reader!/0`.
23. Implement `Scry2.Collection` public module (top-level facade).
24. Write tests for `Scry2.Collection.RefreshJob` (run inline via
    `Oban.Testing`).
25. Implement `RefreshJob` — wires Reader.run + Snapshot.create, with
    self-check gate.
26. Add `collection` queue to `config/config.exs` Oban config.

**Phase 7 — Topics integration**

27. Add `Scry2.Topics.collection_snapshots/0` returning `"collection:snapshots"`.
28. `Collection.save_snapshot/1` broadcasts on this topic.
29. Update `Scry2.Topics`' moduledoc to list the new topic.

**Phase 8 — LiveView surface**

30. Write LiveView integration tests (mount + refresh button +
    consent-modal flow).
31. Create `Scry2Web.CollectionLive` with three states:
    disabled (banner + enable button), enabled-no-snapshot (refresh
    button), enabled-with-snapshot (stats + cards grid).
32. Consent modal component with Spike 15's disclosure copy.
33. Add route to `router.ex`.
34. Add "Collection" nav link to the main layout.

**Phase 9 — CLAUDE.md and CI**

35. Update CLAUDE.md:
    - Add `Collection` row to bounded contexts table.
    - Add "Rust toolchain" to dev setup notes.
    - Reference ADR 034.
36. Update `.github/workflows/ci.yml` to install Rust toolchain and
    run tests.
37. Update `.github/workflows/release.yml` build matrix to install
    Rust toolchain on each platform runner before `mix compile`. No
    new packaging steps; `priv/native/` is already in the release.
38. Update `installer/scripts/build-msi.ps1` fragment generator to
    include `priv/native/*.dll` (verify — it likely already does).
39. Regenerate CLAUDE.md's architecture overview table.

**Phase 10 — release gating and kill switch**

40. Verify `mix precommit` passes on every change (per scry_2
    conventions).
41. Manual test against live MTGA on Linux and Windows.
42. Cut a dev release; confirm end-to-end install + enable + refresh
    cycle on both platforms.
43. Document the kill-switch procedure inline in the context module:
    set `collection.reader_enabled` to "false" to disable; remove the
    Rust crate + context module in a future release if enforcement
    posture changes.

### Files to modify

**Configuration and build:**

- `mix.exs` — add `{:rustler, "~> 0.32"}` dep; add `rustler_crates:
  [scry2_collection_reader: [path: "native/scry2_collection_reader"]]`
  to `project`.
- `config/config.exs` — add `:collection` to Oban queues; configure
  `Scry2.Collection` mem backend.
- `config/test.exs` — configure TestBackend.
- `config/dev.exs` — same as prod config.
- `.gitignore` — `/native/**/target/`.
- `.mise.toml` (or `.tool-versions`) — add `rust` channel.
- `.github/workflows/ci.yml` — `dtolnay/rust-toolchain@stable` step
  before `mix deps.get`.
- `.github/workflows/release.yml` — same Rust toolchain step on each
  `build` matrix job.
- `lib/scry_2/topics.ex` — add `collection_snapshots/0`.
- `lib/scry_2_web/router.ex` — add `/collection` live route.
- `lib/scry_2_web/components/layouts.ex` (or equivalent) — add nav link.

**New files:**

- `native/scry2_collection_reader/Cargo.toml`
- `native/scry2_collection_reader/src/lib.rs`
- `native/scry2_collection_reader/src/linux.rs`
- `native/scry2_collection_reader/src/windows.rs`
- `native/scry2_collection_reader/src/macos.rs`
- `native/scry2_collection_reader/src/common.rs`
- `lib/scry_2/collection.ex` — public facade
- `lib/scry_2/collection/mem.ex` — behaviour
- `lib/scry_2/collection/mem/nif.ex` — Rustler wrapper
- `lib/scry_2/collection/mem/test_backend.ex` — for tests
- `lib/scry_2/collection/reader.ex` — walker + scanner
- `lib/scry_2/collection/snapshot.ex` — Ecto schema
- `lib/scry_2/collection/refresh_job.ex` — Oban worker
- `lib/scry_2_web/live/collection_live.ex`
- `lib/scry_2_web/live/collection_live.html.heex`
- `priv/repo/migrations/<TS>_create_collection_snapshots.exs`
- `test/scry_2/collection/collection_test.exs`
- `test/scry_2/collection/reader_test.exs`
- `test/scry_2/collection/snapshot_test.exs`
- `test/scry_2/collection/refresh_job_test.exs`
- `test/scry_2/collection/mem/test_backend_test.exs`
- `test/scry_2/collection/mem/nif_test.exs` (`@tag :external`)
- `test/scry_2_web/live/collection_live_test.exs`
- `test/support/fixtures/collection/*.bin` — memory fixtures for
  walker/scanner tests

### Technical decisions

- **Plain Rustler, not `rustler_precompiled`.** scry_2 publishes its
  own releases per-platform; we don't need to ship a NIF package to
  other Elixir apps. CI builds the NIF from source on each platform.
- **NIF dirty-IO scheduler for all blocking calls.** Non-negotiable;
  regular scheduler would starve BEAM work.
- **`process_vm_readv` over `/proc/<pid>/mem`** on Linux — slightly
  faster per-call, scatter/gather support, same kernel gate.
- **Walker path as primary, scan as fallback.** Walker gives clear
  failure modes and the path to inventory/wildcards/gold. Scan is
  pre-validated (POC + Elixir feasibility) as a safety net.
- **No GenServer for v1.** On-demand refresh via Oban queue is
  stateless from Elixir's perspective; the queue provides serialisation.
  Revisit if live-tracking becomes a requirement (Spike 8 / live-tracking.md).
- **Panic-free NIF by construction.** `#[deny(clippy::panic,
  clippy::unwrap_used, clippy::expect_used)]` enforced in CI.
- **macOS ships with stub implementations** so the shape is uniform
  and the test suite can cover macOS `Mem.Nif.read_bytes/3` returning
  `{:error, :not_implemented}`. Real macOS implementation is a follow-up
  ADR when we have a test machine.
- **Feature flag via Settings.Entry**, not compile-time. Matches the
  kill-switch requirement (operator can disable without recompile).
  The reader code is still shipped; the flag gates the refresh job.
- **Append-only `collection_snapshots`**. Retention policy deferred.
- **No domain-events emitted from memory reads** in v1. Per
  `log-vs-memory-authority.md`, memory is a parallel read-side source;
  the event log keeps its single-publisher-per-topic invariant.
  Divergence detection compares memory snapshot vs log-derived lower
  bound; flags unexpected gaps in the log parser.
- **Kill-switch design:** A single "disable" release removes the
  `/collection` route, sets the feature flag default to false, and
  tombstones the Oban worker to refuse new runs. A follow-up release
  drops the Rust crate and context module entirely.

### Scope estimate

From the Spike 14 estimate (90–110 hrs) adjusted per the
rust-integration note (thin NIF is a wash, +4-6 hrs for toolchain, -8-12
hrs for dropped port-lifecycle):

| Work | Hours |
|---|---|
| Rust crate (linux + windows branches, macos stub) + tests | 12 |
| CI Rust toolchain + release workflow updates | 4 |
| Mem behaviour + TestBackend | 3 |
| Reader — PE export table parsing + Mono prologue detection | 4 |
| Reader — walker implementation with Mono struct offsets | 18 |
| Reader — structural-scan fallback (port from mtga-duress scan.exs) | 4 |
| Reader — self-check gate | 4 |
| Snapshot schema + migration + factory | 3 |
| Collection facade + RefreshJob + Topics integration | 6 |
| LiveView (view + consent modal + divergence banner) | 12 |
| Tests (unit + LiveView + integration) | 10 |
| Documentation (CLAUDE.md + ADR polish + inline docs) | 4 |
| Release validation (Linux + Windows manual tests) | 6 |
| **Total** | **~90** |

Staging: Phases 1–4 in ~25 hrs give a callable reader without
persistence or UI. Phases 5–7 in another ~15 hrs land storage and the
Oban worker. Phases 8–10 close it off.

## Related Records

- [`decisions/architecture/2026-04-05-017-event-sourcing-core-architecture.md`](./2026-04-05-017-event-sourcing-core-architecture.md)
- [`decisions/architecture/2026-04-05-018-anti-corruption-layer-mtga-domain.md`](./2026-04-05-018-anti-corruption-layer-mtga-domain.md)
- [`decisions/architecture/2026-04-20-033-elixir-native-self-update.md`](./2026-04-20-033-elixir-native-self-update.md)
  — precedent for an owned-in-Elixir subsystem replacing a native one.
- [`mtga-duress/research/001-mtga-collection-acquisition.md`](../../../mtga-duress/research/001-mtga-collection-acquisition.md)
- [`mtga-duress/research/002-mtga-memory-reader-design.md`](../../../mtga-duress/research/002-mtga-memory-reader-design.md)
- [`mtga-duress/experiments/notes/live-tracking.md`](../../../mtga-duress/experiments/notes/live-tracking.md)
- [`mtga-duress/experiments/notes/log-vs-memory-authority.md`](../../../mtga-duress/experiments/notes/log-vs-memory-authority.md)
- [`mtga-duress/experiments/notes/windows-platform.md`](../../../mtga-duress/experiments/notes/windows-platform.md)
- [`mtga-duress/experiments/notes/rust-integration.md`](../../../mtga-duress/experiments/notes/rust-integration.md)

## Revision 2026-04-25 — walker in Rust

### What changed

The original "thin NIF (three primitives) + Elixir walker" decision has
been revised. The walker now lives in the Rust crate and is exposed
through the NIF as a fourth function:

```
walk_collection(pid) ::
  {:ok, %{
    cards:           [{arena_id :: integer, count :: integer}, ...],
    wildcards:       %{common: integer, uncommon: integer, rare: integer, mythic: integer},
    gold:            integer,
    gems:            integer,
    vault_progress:  integer,
    build_hint:      String.t() | nil,
    reader_version:  String.t()
  }} | {:error, atom}
```

Elixir retains: `Scry2.Collection.Reader` orchestration (find pid, list
maps, invoke walker, fall back to scanner on failure), the self-check
gate (plausibility validation on the returned map), snapshot
persistence, the scanner fallback (kept in Elixir — it processes bulk
heap regions in a single pass, a workload Elixir handles cleanly), and
the LiveView surface.

### Why

- Mono exposes ~10 C structs on the pointer chain (`MonoDomain`,
  `MonoAssembly`, `MonoImage`, `MonoClass`, `MonoClassField`,
  `MonoVTable`, `MonoObject`, `MonoArray`, and the generic dictionary
  internals). Each has 5–15 offset-addressed fields.
- Decoding these in Elixir means hand-rolled bitstring pattern matches
  for every field, with offset constants as module attributes. Error
  prone — one wrong offset produces silent garbage data with no compile
  time signal.
- Rust handles this natively with `#[repr(C)]` struct casts; the
  compiler enforces field layouts and errors show up at build time, not
  as cryptic runtime values.
- Performance was **not** the driver. The walker reads < 1 MB total in
  small targeted chunks — an Elixir port would be fast enough. The
  3.7 s vs 1.4 s figure from research 002 measured the structural
  **scan** (megabytes of heap), not the walker.

### Consequences of the revision

- **Good**: Mono struct decoding is compiler enforced; offset mistakes
  fail at build time, not as silent garbage. The walker lives where its
  data naturally lives.
- **Good**: One NIF boundary crossing per walk instead of ~20–50. Not a
  runtime issue for one-shot reads, but a cleaner contract.
- **Neutral**: the "95% Elixir logic" design value is relaxed for the
  Collection subsystem specifically. It still holds for every other
  context — Collection is an explicit exception where the natural shape
  of the work is C struct decoding.
- **Bad**: more Rust surface (estimated +300–500 LoC). Walker changes
  require rebuilding the NIF; attribute edits in Elixir no longer
  suffice.
- **Neutral**: walker unit tests live in Rust with byte fixtures
  (`#[cfg(test)] mod tests`). The planned `Mem.TestBackend` in Elixir
  remains — it still tests the primitives path and the reader's
  orchestration with a stubbed walker result.

### Phases affected

- **Phase 2/3** (Elixir Mem behaviour + Elixir walker) contract. The
  TestBackend still exists, but its walker test scope moves to Rust.
- **Phase 4** (Rust NIF) grows to include the walker plus its tests.
- **Phase 5 onward** unchanged: schema, facade, Oban worker, LiveView.
