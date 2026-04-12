Read `AGENTS.md` for Elixir, Phoenix, LiveView, Ecto, and CSS/JS guidelines.

## Automation Philosophy

**Prefer scripts over AI workflows for repeatable tasks.** When the steps are known and mechanical, write a shell script — don't reach for subagents, hooks, or AI-driven loops. Scripts are auditable, fast, version-controlled, and token-free. Reserve AI workflows for tasks that require judgment or adaptation at runtime.

## Data Integrity

**Data loss is unacceptable.** Every decision that touches the database, file ingestion, migrations, or database replacement must preserve all existing data. This includes:

- **Never replace or overwrite a database** without first verifying the target has all data the source has, or explicitly merging both datasets.
- **Never drop or truncate tables** that contain user data without a recovery path.
- **Migrations must be reversible** and must not silently discard rows (e.g., dropping a column with data).
- **Ingestion must be idempotent and complete.** If an event could be lost (rotation, crash, restart), the pipeline must have a mechanism to recover it — not just detect the loss after the fact.
- **When in doubt, backup first.** Before any destructive operation (database swap, schema change, bulk update), snapshot the current state.

The MTGA event log is irreplaceable once MTGA rotates it. Every raw event must be persisted before any downstream processing touches it.

## Design Philosophy

**Only the best software design is worth building. No half-measures.** When in doubt, invest in structure over quick wins.

This app has high ambitions — many real-time consumers, rich analytics, long-lived codebase. Every design decision is made with the assumption that the code will live longer than any individual feature. Prefer:

- **Explicit contracts over implicit conventions.** Typed structs, named events, documented boundaries.
- **Typed domain events over passing raw maps.** Every fact that crosses a context boundary is a named struct with `@enforce_keys` and a `@type t`.
- **Bounded contexts over sprawling modules.** Each context owns its tables, its vocabulary, and its public API. Cross-context communication goes through PubSub.
- **Persistent event logs + projections over direct writes.** See ADR-017 for the event-sourced architecture.
- **Self-documenting code over external documentation.** Pipeline stages are visible from module @moduledocs; no mental reverse-engineering required.

When two designs both work, pick the one that scales better, not the one that ships faster. If a refactor would pay back across multiple future sessions, do it now — waiting only increases the cost.

## Skills-First Development

**Always invoke the appropriate thinking skill BEFORE exploring code or writing implementation.** Skills contain paradigm-shifting insights that guide what patterns to look for and what anti-patterns to avoid.

| Area | Skill |
|------|-------|
| General Elixir implementation, refactoring, architecture | `elixir-thinking` |
| LiveView, PubSub, components, mount | `phoenix-thinking` |
| Ecto, schemas, changesets, contexts, migrations | `ecto-thinking` |
| GenServer, Supervisor, Task, ETS, concurrency | `otp-thinking` |
| Oban, background jobs, workflows, scheduling | `oban-thinking` |
| Writing tests — Elixir, JavaScript, or Playwright E2E | `automated-testing` |
| General coding standards, naming, structure | `coding-guidelines` |
| UI work — templates, components, CSS, styling, layout | `user-interface` |
| Events, domain events, MTGA event types, anti-corruption layer | `events` |
| Production debugging, service health, runtime logs | `troubleshoot` |
| Platform paths, config, install scripts, tray binary, CI | `platform-compatibility` |

Invoke the skill **first**, then explore the codebase, then write code.

# Scry2

Scry2 is a Phoenix/Elixir backend worker with a LiveView admin UI. It monitors Magic: The Gathering Arena's `Player.log` file, parses MTGA events, and persists them to a local SQLite database. It imports card reference data from 17lands' public datasets. The project is inspired by 17lands.com and self-hosted for one player's data.

## Version Control (Jujutsu)

All repositories use **JJ (Jujutsu)** — never use raw `git` commands.

- After completing a feature: `jj describe -m "type: short description"`
- Use conventional commit style (e.g. `feat:`, `fix:`, `refactor:`). Concise and high-level.
- Amend the existing change for follow-up fixes (if not yet pushed).
- Start unrelated features with `jj new`.
- Adjust the description as scope becomes clearer.

## Build & Run

```bash
mix setup              # install deps, create DB, run migrations, build assets
mix phx.server         # start dev server (http://localhost:4444)
mix test               # run tests (creates and migrates test DB automatically)
mix precommit          # compile --warning-as-errors, unlock unused deps, format, test
```

### Dev service

```bash
scripts/install-dev    # install systemd user service for dev server
```

The dev server can run as a persistent systemd user service. `scripts/install-dev` installs a unit that runs `mix phx.server` via `mise exec`, with a named BEAM node for remote shell access.

```bash
systemctl --user start scry-2-dev     # start
systemctl --user stop scry-2-dev      # stop
journalctl --user -u scry-2-dev -f    # logs
iex --name repl@127.0.0.1 --remsh scry_2_dev@127.0.0.1   # REPL
```

Disconnect the REPL with `Ctrl+\` (leaves the server running).

### Release

```bash
scripts/release              # build prod release + tray, stage to _build/prod/package/
scripts/install              # build + install locally in one step (for devs who
                             #   also run the production app for gameplay analysis)
scripts/tag-release 0.2.0    # run precommit, bump version, tag, push — triggers CI
```

The release workflow:

1. **Local build** — `scripts/release` builds the Elixir release and tray binary, stages everything in `_build/prod/package/`. Use this to verify a release builds before tagging.
2. **Local install** — `scripts/install` builds and installs in one step. Use this to test the production release on your machine, or to keep the production app installed for your own gameplay analysis.
3. **Tag and publish** — `scripts/tag-release <version>` runs `mix precommit`, bumps the version in `mix.exs`, creates a jj tag, and pushes to GitHub. GitHub Actions then builds all three platform archives (Linux, macOS, Windows) and publishes them to GitHub Releases.

The CI build is authoritative for multi-platform releases. `scripts/release` and `scripts/install` are for local development and testing only. Platform-specific package installers live at `scripts/install-linux` and `scripts/install-macos` — these are copied into the release package and run *from inside* it, not from the repo root.

Migrations in a release: `bin/scry_2 eval "Scry2.Release.migrate()"`.

> Note: When compiling, always use the environment variable `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8` to parallelize and speed up compilation.

### Running dev and prod simultaneously

Dev runs on port 4444 and prod runs on port 6015 — they do not conflict by default.

Each instance has its own independent database (`scry_2_dev.db` in the project root for dev; `~/.local/share/scry_2/scry_2.db` for prod). Both watch `Player.log` and ingest events independently — there is no shared state between the two environments.

### Windows Installation

Windows has two distribution paths, both built in CI (no local Windows build):

| Path | Install location | Artifact | Installer |
|------|-----------------|----------|-----------|
| **Zip** | `%LOCALAPPDATA%\scry_2` | `.zip` archive | `install.bat` / `uninstall.bat` |
| **MSI** | `C:\Program Files\Scry2` | `Scry2Setup-*.exe` (Burn bootstrapper) | WiX v5 MSI + bundled VC++ Redist |

The MSI path uses WiX v5 (config in `installer/wix/`, build script `installer/scripts/build-msi.ps1`). The Burn bootstrapper wraps the MSI and auto-installs the Visual C++ Redistributable if missing. It also creates Windows Firewall rules for EPMD and the Erlang VM, and handles legacy cleanup from older zip-based installs.

Both paths register autostart via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` and start the tray binary, which launches the Elixir backend.

**`SCRY2_QUIET=1`** — suppresses `pause` prompts and skips the runtime eval check in `install.bat` and `uninstall.bat` for non-interactive use (CI). The eval check starts the full OTP app which hangs without `Player.log`.

**WiX v5 pitfalls** (learned the hard way):
- **Fragments must be explicitly referenced.** WiX v5's linker only includes fragments reachable from `<Package>`. Add `<FeatureRef>` in Package.wxs to pull in Features from other files.
- **`SourceFile` paths resolve from CWD**, not the .wxs file location. Use repo-relative paths (e.g. `installer/wix/LegacyCleanup.bat`).
- **Use `ProgramFiles64Folder`** not `ProgramFiles6432Folder` for 64-bit installs. The latter resolves to `Program Files (x86)`.
- **Directory nesting in generated fragments** must properly close sibling directories. Build the directory tree in a first pass, then emit components in a second pass using `<DirectoryRef>`.
- **`build-msi.ps1` generates fragments programmatically** because WiX v5's `<Files>` element doesn't work reliably with the CLI tool. The fragments enumerate every file in the Elixir release and create Component/File/Directory entries.

### Tray Binary

The system tray binary (`tray/`, Go) is the user-facing entry point on all platforms. It:

- Starts and stops the Elixir backend (`bin/scry_2 start/stop`)
- Provides a system tray icon with menu (open browser, quit)
- Opens the browser to `http://localhost:6015` on first launch
- Handles self-update: downloads new releases and runs the appropriate installer

Two Windows variants are built with different `-ldflags`:
- **Zip variant** (`scry2-tray.exe`): updater downloads `.zip` and runs `install.bat`
- **MSI variant** (`scry2-tray-msi.exe`): updater downloads and runs the Burn bootstrapper `.exe`

The version and installer type are stamped at build time via `-X 'scry2/tray/updater.CurrentVersion=...'` and `-X 'scry2/tray/updater.InstallerType=msi'`.

### CI Workflows

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `ci.yml` | Push to `main`, PRs | Format check, compile (warnings-as-errors), test suite (Ubuntu) |
| `tray-ci.yml` | Push to `main`, PRs | Go tray unit tests on Ubuntu, macOS, and Windows |
| `release.yml` | Version tags (`v*`) | Test gate → build release archives + MSI for all 3 platforms → publish to GitHub Releases |
| `windows-install-test.yml` | Changes to `installer/`, `rel/overlays/`, `tray/`, `mix.exs`; manual dispatch | Builds Windows artifacts, then tests both zip and MSI install/uninstall on a real Windows runner (file layout, registry, runtime eval, HTTP health check, cleanup) |

Run `mix precommit` before finishing any set of changes and fix all issues it reports.

**Zero warnings policy.** Application code and tests must compile and run with zero warnings. This applies to our own code only — warnings from third-party dependencies are excluded. This includes unused variables, unused aliases, unused imports, and any log output during tests that indicates misconfiguration (e.g., HTTP requests hitting real endpoints instead of stubs). Treat every warning as a bug — fix it before moving on.

## Observability for Debugging

Every system — Elixir, JavaScript, or otherwise — must be designed so that Claude Code can get diagnostic feedback when something goes wrong at runtime. Tests passing while the app is broken means the observability gap is the first problem to solve.

- **Elixir/OTP:** The thinking log system (`Scry2.Log`) already covers this. Use it.
- **New systems:** If it's not immediately obvious how to get runtime diagnostic output back to Claude Code, stop and consult with the user on how it should work before proceeding with the fix. Don't guess — the feedback loop is a prerequisite.

## Architecture Principles

- **This app owns all writes to the scry_2 SQLite database.**
- **17lands cards.csv is the source of truth for card reference data.** Scryfall is the source for `arena_id` backfill.
- **`arena_id` (MTGA's 5-digit card identifier) is the stable join key** for all log-derived data — never mutate it. See [ADR-014](decisions/architecture/2026-04-05-014-arena-id-as-stable-key.md).
- **All cross-context communication goes through `Scry2.Topics` PubSub helpers** — never call another context's modules directly.
- **The watcher is a read-only consumer of `Player.log`.** Scry2 never writes to MTGA files.
- **Every parsed log event retains its raw JSON in `mtga_logs_events` for replay.** This is the core data-integrity guarantee. See [ADR-015](decisions/architecture/2026-04-05-015-raw-event-replay.md).
- **All match/draft upserts are idempotent via MTGA's own IDs** — reprocessing any log range must yield identical state. See [ADR-016](decisions/architecture/2026-04-05-016-idempotent-log-ingestion.md).
- **Event sourcing is the core architecture for MTGA ingestion.** Raw events → IdentifyDomainEvents (anti-corruption layer) → domain events → projections. See [ADR-017](decisions/architecture/2026-04-05-017-event-sourcing-core-architecture.md) and [ADR-018](decisions/architecture/2026-04-05-018-anti-corruption-layer-mtga-domain.md).
- **MTGA wire format lives in exactly one module: `Scry2.Events.IdentifyDomainEvents`.** Every downstream consumer works with typed domain event structs under `Scry2.Events.*` and subscribes to `domain:events`. No downstream context touches `mtga_logs_events` directly.
- **Projections are disposable read models.** `matches_*` and `drafts_*` tables can be dropped and rebuilt from the domain event log at any time via `Scry2.Events.replay_projections!/0`.

## MTGA: Detailed Logs Required

Scry2 needs MTGA to emit structured JSON event data. The user must enable
**Options → View Account → Detailed Logs (Plugin Support)** inside MTGA.
Without this setting, `Player.log` only contains plain-text entries and
Scry2 will warn on the dashboard that no events can be parsed.

This is the single most common user-error mode. The watcher emits a
`detailed_logs_warning` broadcast to `mtga_logs:status` if the first N
events lack the expected structured payloads.

## 17lands Data Provenance

Card reference data is imported from 17lands' public dataset at
<https://17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv>.
Licensed CC BY 4.0. Attribution is required if this data is ever
re-exposed. See `Scry2.Cards.SeventeenLands`.

## Data Model

See `decisions/architecture/2026-04-05-014-arena-id-as-stable-key.md` and the schema modules under `lib/scry_2/cards/`, `lib/scry_2/match_listing/`, `lib/scry_2/draft_listing/` for the data model. Type-specific tables, no polymorphic entity table.

## Bounded Contexts

Each context owns its tables and communicates only via PubSub events. No context aliases another context's modules. Ingestion is a two-context subsystem (`MtgaLogIngestion` + `Events`); downstream projection contexts subscribe to `domain:events` only.

| Context | Prefix | Owns | PubSub role |
|---|---|---|---|
| **MtgaLogIngestion** | `mtga_logs_` | raw log events (`mtga_logs_events`), parser cursor (`mtga_logs_cursor`) | Broadcasts `mtga_logs:events` (raw) and `mtga_logs:status` |
| **Events** | `domain_events` | domain event log, IdentifyDomainEvents (anti-corruption layer), IngestRawEvents | Subscribes `mtga_logs:events`; broadcasts `domain:events` |
| **Matches** | `matches_` | matches, games, deck submissions (projection) | Subscribes `domain:events` via `Matches.Match`; broadcasts `matches:updates` |
| **Drafts** | `drafts_` | drafts, draft picks (projection) | Subscribes `domain:events` via `Drafts.Draft`; broadcasts `drafts:updates` |
| **Cards** | `cards_` | cards, sets (from 17lands) | Broadcasts `cards:updates` |
| **Settings** | `settings_` | runtime config entries | Broadcasts `settings:updates` |
| **Console** | — | in-memory log ring buffer (dev observability) | Broadcasts `console:logs` |

**Key rule:** Only `Scry2.Events.IngestRawEvents` subscribes to `mtga_logs:events`. Every other consumer subscribes to `domain:events` and works with typed `%Scry2.Events.*{}` structs. See ADR-018 for the anti-corruption boundary.

Consumers (LiveViews, Oban workers) may read any context's public API freely. No context aliases another context's modules.

## UI Design

See the layout and components under `lib/scry_2_web/components/` for the UI patterns. Dark theme, Tailwind 4, daisyUI.

## Decision Records

Decision records live in `decisions/` using [MADR 4.0](https://adr.github.io/madr/). See `decisions/README.md` for the category index. **Filename convention:** `YYYY-MM-DD-NNN-short-title.md`, numbered per category.

- **Architecture** (`decisions/architecture/`): system design, data model, integration patterns, engineering standards
- **User Interface** (`decisions/user-interface/`): component conventions, styling rules, visual design decisions

## Defaults

The `defaults/` directory contains git-tracked defaults for every config key recognised by `Scry2.Config`, with inline comments. Override via `~/.config/scry_2/config.toml`. The file is a template — it is never loaded directly at runtime. Keep `defaults/scry_2.toml` complete and valid TOML.

## Testing Strategy

Load the `automated-testing` skill before writing any test — Elixir, JavaScript, or Playwright E2E. It covers test-first workflow, factory patterns, stub strategies, E2E parameterization, and all project testing policies.

**Test-first.** Write tests before implementation for all new features and bug fixes. Tests are the executable specification — if you can't write the test, the requirements aren't clear enough.

**Zero tolerance for flaky tests.** Every test must pass deterministically, every time. A flaky test is a bug — diagnose and fix the root cause before moving on. Never ignore, skip, or retry a flaky test.

### Pure Function Tests vs Resource Tests

- **Pure function modules** (ExtractEventsFromLog, IdentifyDomainEvents, etc.) use `async: true` and build struct literals via factory — no database.
- **Resource tests** (Match, Draft, Card, WatchedFile) use `DataCase` and exercise against the real database.

### Shared Test Factory

`test/support/factory.ex` provides `Scry2.TestFactory`:

- `build_*` functions return plain structs with sensible defaults (no DB). Use for pure function tests.
- `create_*` functions persist records and return loaded records. Use for resource tests.

All tests that need test data use the factory.

### LiveView Logic Extraction (Mandatory)

All non-trivial logic in LiveViews and function components must be extracted into public pure functions and unit tested ([ADR-013](decisions/architecture/2026-04-05-013-liveview-logic-extraction.md)). LiveViews should be thin wiring — mount, event dispatch, and template rendering. Any `if`, `case`, `cond`, or `Enum` pipeline on domain data belongs in an extracted function. Extract into the same module (small helpers) or a dedicated helper module (larger clusters). Test with `async: true` and `build_*` factory helpers.

### What We Never Test

- **GenServer message protocols** — never use `:sys.get_state`, `:sys.replace_state`, or direct `GenServer.call/cast` in tests. Always test through the module's public API ([ADR-009](decisions/architecture/2026-04-05-009-genserver-api-encapsulation.md)). GenServers with testable public logic should be tested. GenServers that are thin wrappers around external systems requiring real connections (Watcher → inotify on `Player.log`) are not worth mocking.
- **Rendered HTML** — never assert on HTML output (`render_component`, `=~` on markup). LiveView integration tests (mount, patch, event handling) are acceptable — they test navigation and data flow, not DOM structure.
- **External API calls** in normal runs — tag `@tag :external` and exclude from default `mix test`.

### Parser Tests (Append-Only)

**Test-first, mandatory.** Every change to `Scry2.MtgaLogIngestion.ExtractEventsFromLog` must have a corresponding test written *before* the implementation. The parser is the core of the application and bugs here are silent and cascading.

- **Real log samples only** — every test fixture is a real MTGA log event block captured from `Player.log`. Fixtures live in `test/fixtures/mtga_logs/`.
- **One test per event type.** Each distinct MTGA event type gets its own test case.
- **NEVER delete or weaken parser tests.** See [ADR-010](decisions/architecture/2026-04-05-010-regression-tests-append-only.md). Each test represents a real scenario — fix the parser, not the test.

## Parser

`Scry2.MtgaLogIngestion.ExtractEventsFromLog` is a pure function module — no GenServer, no DB, no side effects. Transforms a raw MTGA log event block into an `%Event{type:, mtga_timestamp:, payload:}` struct. See its `@moduledoc` for supported event types. Real log samples only in tests (`test/fixtures/mtga_logs/`). One test per event type. NEVER delete parser tests (see [ADR-010](decisions/architecture/2026-04-05-010-regression-tests-append-only.md)).

## Thinking Logs

The app has a component-tagged logging system for development visibility. All log entries flow through an Erlang `:logger` handler into an in-memory ring buffer (`Scry2.Console.RecentEntries`, default 2,000 entries) and are viewable in the browser via the Guake-style **Console** drawer (press `` ` `` backtick). Filter visibility is UI-driven — there is no source-level suppression.

### Usage

```elixir
require Scry2.Log, as: Log
Log.info(:ingester, "processed 3 events")
Log.info(:http, fn -> "response: #{inspect(data, limit: 5)}" end)
Log.warning(:watcher, "backlog: #{count} events")
Log.error(:importer, "failed to persist card: #{inspect(reason)}")
```

The `Scry2.Log` module contains only the `info/2`, `warning/2`, and `error/2` macros — call sites never change.

### Components

The handler classifies every entry into one component:

| Component | Source |
|-----------|--------|
| `:watcher` | Explicit via `Log.info(:watcher, ...)` — `Player.log` file events, tail progress |
| `:parser` | Explicit — MTGA event parsing, unknown event types |
| `:ingester` | Explicit — raw-event persistence, downstream dispatch |
| `:importer` | Explicit — 17lands CSV import, Scryfall backfill |
| `:http` | Explicit — API calls, rate limiting, fetch results |
| `:system` | Fallback — any log without a component tag and no framework prefix |
| `:phoenix` | Automatic — logs from `Phoenix.*` modules |
| `:ecto` | Automatic — logs from `Ecto.*`, `Exqlite.*`, `DBConnection.*` |
| `:live_view` | Automatic — logs from `Phoenix.LiveView.*` modules |

Framework components (`:phoenix`, `:ecto`, `:live_view`) default to HIDDEN in the console filter. Flip their chips to see Ecto queries or Phoenix request logs.

### Accessing the buffer

- **Browser:** press `` ` `` from any page to open the sticky drawer, or navigate to `/console` for the full-page view. Filter chips, level segment, and text search are all live.
- **IEx/Remote shell:** `Scry2.Diagnostics.log_recent(20)` prints the 20 most recent entries. `Scry2.Console.recent_entries/1` returns them as `%Entry{}` structs.

### Architectural notes

- The bounded context `Scry2.Console` owns the buffer, handler, filter, and view helpers. LiveViews interact only through the `Scry2.Console` public facade.
- The buffer survives page navigation and reload (sticky LiveView + server-side state). It is lost on BEAM restart.
- Filter state and buffer size are persisted per-user to `Settings.Entry` with a 2-second debounce.

## CSS Animation Rules

- **Never use CSS `animation` (keyframes) on LiveView stream items.** LiveView morphdom re-inserts stream elements on re-render (`reset_stream`, `push_patch`), replaying all animations. This causes visible flashes across the entire grid. Use `phx-mounted` + `JS.transition()` instead — it only fires on DOM insertion and survives morphdom patches.
- **Minimize `reset_stream` calls.** In `handle_params`, compare grid-affecting params against current assigns and only reset when they changed. Selection-only changes (e.g. modal open/close) must skip the reset to avoid unnecessary DOM teardown.
- **`backdrop-filter: blur()` elements must stay in the DOM.** Never use `:if={}` to conditionally render elements with `backdrop-filter`. The browser pays a compositing setup cost on every insertion. Instead, keep the element always rendered and toggle with `data-state` + `visibility: hidden` / `pointer-events: none`.
- **Only animate `opacity` and `transform`.** These are the only compositor-only (GPU-cheap) properties. Animating `background`, `backdrop-filter`, `box-shadow`, or any layout property on a backdrop-filter element forces expensive per-frame recompositing.

## LiveView Callbacks

- **Annotate every callback group with `@impl true`.** Place `@impl true` before the first clause of each callback function name (`mount`, `render`, `handle_event`, `handle_info`, `handle_params`). This is the convention used across all LiveViews in this project.
- **Distinguish mount from selection change in `handle_params`.** On mount, selected IDs are `nil`. When a URL param like `selected=X` is present, `handle_params` sees `nil → X` as a "change." If you need to reset state only when the user *switches* entities (not on initial load), check that the previous value was non-nil. This ensures URL params like `view=info` survive page reload.

## Variable Naming

Write code for humans to read first, compilers second.

- **Never abbreviate** variables to save keystrokes. `event` not `ev`, `match` not `m`,
  `card` not `c`, `result` not `res`.
- Name the variable what the value *is*, not what type it came from. If you parsed a log
  event block representing a draft pick, call it `pick` or `draft_pick`, not `event` or `ev`.
- This rule applies everywhere: tests, GenServers, LiveViews, changesets.
