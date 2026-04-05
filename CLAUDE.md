Read `AGENTS.md` for Elixir, Phoenix, LiveView, Ecto, and CSS/JS guidelines.

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
| Production debugging, service health, runtime logs | `troubleshoot` |

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
mix phx.server         # start dev server (http://localhost:4002)
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
scripts/release              # build production release
scripts/install              # install to ~/.local/lib/scry_2/ and set up systemd
```

Manual build (if needed):

```bash
MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release   # build release
_build/prod/rel/scry_2/bin/scry_2 start                      # run release
```

Migrations in a release: `bin/scry_2 eval "Scry2.Release.migrate()"`.

> Note: When compiling, always use the environment variable `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8` to parallelize and speed up compilation.

Run `mix precommit` before finishing any set of changes and fix all issues it reports.

**Zero warnings policy.** Application code and tests must compile and run with zero warnings. This includes unused variables, unused aliases, unused imports, and any log output during tests that indicates misconfiguration (e.g., HTTP requests hitting real endpoints instead of stubs). Treat every warning as a bug — fix it before moving on.

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
re-exposed. See `Scry2.Cards.Lands17Importer`.

## Data Model

See `decisions/architecture/2026-04-05-014-arena-id-as-stable-key.md` and the schema modules under `lib/scry_2/cards/`, `lib/scry_2/matches/`, `lib/scry_2/drafts/` for the data model. Type-specific tables, no polymorphic entity table.

## Bounded Contexts

Each context owns its tables and communicates only via PubSub events. No context aliases another context's modules.

| Context | Prefix | Owns | PubSub role |
|---|---|---|---|
| **MtgaLogs** | `mtga_logs_` | raw log events, file-watch state, parser cursor | Broadcasts `mtga_logs:events` and `mtga_logs:status` |
| **Matches** | `matches_` | matches, games, deck submissions | Subscribes `mtga_logs:events`; broadcasts `matches:updates` |
| **Drafts** | `drafts_` | drafts, draft picks | Subscribes `mtga_logs:events`; broadcasts `drafts:updates` |
| **Cards** | `cards_` | cards, sets (from 17lands) | Broadcasts `cards:updates` |
| **Settings** | `settings_` | runtime config entries | Broadcasts `settings:updates` |

Consumers (LiveViews, Oban workers) may read any context's public API freely. No context aliases another context's modules.

## UI Design

See the layout and components under `lib/scry_2_web/components/` for the UI patterns. Dark theme, Tailwind 4, daisyUI.

## Decision Records

Decision records live in `decisions/` using [MADR 4.0](https://adr.github.io/madr/). See `decisions/README.md` for the category index. **Filename convention:** `YYYY-MM-DD-NNN-short-title.md`, numbered per category.

- **Architecture** (`decisions/architecture/`): system design, data model, integration patterns, engineering standards

## Defaults

The `defaults/` directory contains git-tracked defaults for every config key recognised by `Scry2.Config`, with inline comments. Override via `~/.config/scry_2/config.toml`. The file is a template — it is never loaded directly at runtime. Keep `defaults/scry_2.toml` complete and valid TOML.

## Testing Strategy

Load the `automated-testing` skill before writing any test — Elixir, JavaScript, or Playwright E2E. It covers test-first workflow, factory patterns, stub strategies, E2E parameterization, and all project testing policies.

**Test-first.** Write tests before implementation for all new features and bug fixes. Tests are the executable specification — if you can't write the test, the requirements aren't clear enough.

**Zero tolerance for flaky tests.** Every test must pass deterministically, every time. A flaky test is a bug — diagnose and fix the root cause before moving on. Never ignore, skip, or retry a flaky test.

### Pure Function Tests vs Resource Tests

- **Pure function modules** (EventParser, Serializer, Mapper) use `async: true` and build struct literals via factory — no database.
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

**Test-first, mandatory.** Every change to `Scry2.MtgaLogs.EventParser` must have a corresponding test written *before* the implementation. The parser is the core of the application and bugs here are silent and cascading.

- **Real log samples only** — every test fixture is a real MTGA log event block captured from `Player.log`. Fixtures live in `test/fixtures/mtga_logs/`.
- **One test per event type.** Each distinct MTGA event type gets its own test case.
- **NEVER delete or weaken parser tests.** See [ADR-010](decisions/architecture/2026-04-05-010-regression-tests-append-only.md). Each test represents a real scenario — fix the parser, not the test.

## Parser

`Scry2.MtgaLogs.EventParser` is a pure function module — no GenServer, no DB, no side effects. Transforms a raw MTGA log event block into an `%Event{type:, mtga_timestamp:, payload:}` struct. See its `@moduledoc` for supported event types. Real log samples only in tests (`test/fixtures/mtga_logs/`). One test per event type. NEVER delete parser tests (see [ADR-010](decisions/architecture/2026-04-05-010-regression-tests-append-only.md)).

## Thinking Logs

The app has a component-tagged logging system for development visibility. All log entries flow through an Erlang `:logger` handler into an in-memory ring buffer (`Scry2.Console.Buffer`, default 2,000 entries) and are viewable in the browser via the Guake-style **Console** drawer (press `` ` `` backtick). Filter visibility is UI-driven — there is no source-level suppression.

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
