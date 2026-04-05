# Scry2 Bootstrap — Remaining Work

Distilled from `RECOVERED_PLAN.md` against the state of commit `caf8d36 feat: bootstrap scry_2 Phoenix backend for MTGA analytics`. The bootstrap commit covers most of Phases A–G (generator, config/TOML, migrations, schemas, contexts, watcher, parser, ingesters, importer, worker, five LiveViews, decision records 001–016). The items below are gaps that remain.

When picking up any of these, invoke the relevant thinking skill first (see `CLAUDE.md` → *Skills-First Development*).

---

## 1. Component-aware logging + Console drawer  — **NOT STARTED**

`CLAUDE.md` documents `Scry2.Log` macros, `Scry2.Console.Buffer`, component tags (`:watcher`, `:parser`, `:ingester`, `:importer`, `:http`, `:system`, `:phoenix`, `:ecto`, `:live_view`), a Guake-style backtick drawer, and a `/console` route — but **none of it exists in `lib/`**. All current call sites still use stdlib `Logger`. This is the biggest gap against the documented architecture.

Adapt verbatim-ish from `/home/shawn/src/media-centaur/backend/lib/media_centaur/log*` + the corresponding Console LiveView. Required pieces:

- `lib/scry_2/log.ex` — `info/2`, `warning/2`, `error/2` macros.
- `lib/scry_2/log/` — `formatter.ex`, `filter.ex`, any helpers from media-centaur.
- `lib/scry_2/console/` — bounded context: `buffer.ex` (ring buffer GenServer, default 2 000 entries), `entry.ex`, `filter.ex`, handler module that plugs into Erlang `:logger`, public facade in `lib/scry_2/console.ex`.
- `Scry2.Diagnostics.log_recent/1` for IEx/remote-shell access.
- Wire the `:logger` handler from `application.ex`.
- `lib/scry_2_web/live/console_live.ex` (+ helpers + tests) and full-page `/console` route.
- Guake-style sticky drawer component bound to backtick key, mounted in the root layout.
- Replace existing `Logger.info(...)` calls in `Scry2.Matches.Ingester`, `Scry2.Drafts.Ingester`, `Scry2.MtgaLogs.Watcher`, `Scry2.Workers.CardsRefreshWorker` with `Log.info(:ingester, …)` / `Log.info(:watcher, …)` / `Log.info(:importer, …)` etc.
- Persist filter state + buffer size per-user to `Settings.Entry` with a 2-second debounce.
- Add the `/console` route to `Scry2Web.Router`.

---

## 2. Real MTGA log fixtures + append-only parser tests  — **NOT STARTED**

`test/fixtures/mtga_logs/` contains only a README. The current `test/scry_2/mtga_logs/event_parser_test.exs` uses **synthetic** fixtures, violating ADR-010 and the project's own parser discipline ("Real log samples only — every fixture is a real MTGA log event block captured from `Player.log`").

This is Plan Risk #5 — the implementing session was told to pause and ask the user to either (a) play a short MTGA session to generate a fresh log, (b) point to an existing `Player.log` on disk, or (c) provide a few anonymized event JSON blocks.

Action:

- Ask the user to supply real event blocks, one per supported event type.
- For each supported type (`EventMatchCreated`, `MatchStart`, `MatchEnd`, `MatchCompleted`, `GameComplete`, `EventDeckSubmit`, `DraftMakePick`, `DraftPack`, `DraftNotify`, `EventJoin`, `EventPayEntry`, `PlayerInventoryGetPlayerCards`, `InventoryUpdate`), drop a fixture file into `test/fixtures/mtga_logs/` named after the event type and add a test case that loads it.
- Scrub opponent screen names + Wizards IDs before committing.
- The existing synthetic tests can stay as parser-unit coverage of the header/brace-balancing machinery, but the per-event-type tests must be real samples.

---

## 3. Ingester persistence logic  — **STUBBED**

Both `lib/scry_2/matches/ingester.ex:60` and `lib/scry_2/drafts/ingester.ex:50` currently call `MtgaLogs.mark_processed!(id)` with a TODO comment. No upserts are performed. This was intentionally deferred until real fixtures exist (item 2 is a prerequisite).

Required work once fixtures exist:

- `Scry2.Matches.Ingester.handle_info/2` — load `%EventRecord{}` by id, dispatch on `type`, call the right `Scry2.Matches` upsert function, then `mark_processed!/1`. Failures must set `processing_error`, not crash the GenServer.
- Same for `Scry2.Drafts.Ingester` (targets `Scry2.Drafts.upsert_draft!/1`, `upsert_pick!/1`).
- Add `Scry2.Matches` / `Scry2.Drafts` public API functions for the upserts with `on_conflict` on the MTGA-side unique keys (`mtga_match_id`, `mtga_draft_id`, `mtga_deck_id`) — idempotency per ADR-016.
- Broadcast `matches:updates` / `drafts:updates` after a successful upsert (ADR-011 mutation-broadcast contract).
- Tests: resource tests using the `create_log_event` factory + real fixtures. Also add an ingester integration test that publishes an event via `Topics` and asserts the upsert happened and the row is marked processed.

---

## 4. Scryfall `arena_id` backfill  — **NOT STARTED**

`RECOVERED_PLAN.md` §"17lands Cards Import" calls out that 17lands `cards.csv` does **not** include MTGA's `arena_id`. A second commit was planned: `Scry2.Cards.ScryfallBackfill` pulls `https://api.scryfall.com/bulk-data` → `default_cards`, cross-references by `(set_code, collector_number)` or `name`, and populates `cards_cards.arena_id`.

Currently `lib/scry_2/cards/lands17_importer.ex:17` just notes that this backfill exists "in a separate path that isn't part of this first import". No such module exists yet.

Before starting this:
- Verify Plan Risk #1 — run `Lands17Importer.run()` against the real file and confirm whether `arena_id` is or isn't present. If 17lands has added it, this item collapses. If not, Scryfall backfill is required and is the only way log events can be joined to card metadata.

Implementation:
- `lib/scry_2/cards/scryfall_backfill.ex` — downloads bulk-data index, fetches `default_cards`, streams JSON, matches by `(set_code, collector_number)` first then `name`, writes only where `arena_id IS NULL` (ADR-014 — never clobber a known `arena_id`).
- `Scry2.Workers.ScryfallBackfillWorker` (Oban) — runs after `CardsRefreshWorker`.
- `Req.Test` stubs under `test/support/scryfall_stubs.ex`.
- Tag real-HTTP tests with `@tag :external`.

---

## 5. LiveView helpers + tests  — **PARTIAL**

ADR-013 requires every LiveView to have extracted pure helpers with `async: true` tests. Current state:

| LiveView | Helpers module | Test |
|---|---|---|
| `DashboardLive` | `dashboard_helpers.ex` ✓ | `dashboard_helpers_test.exs` ✓ — but no **mount/integration** test |
| `MatchesLive` | `matches_helpers.ex` ✓ | `matches_helpers_test.exs` ✓ — no integration test |
| `CardsLive` | `cards_helpers.ex` ✓ | `cards_helpers_test.exs` ✓ — no integration test |
| `DraftsLive` | **missing** | **missing** |
| `SettingsLive` | **missing** | **missing** |
| `ConsoleLive` | n/a — module itself missing (see item 1) | n/a |

Action:
- Create `lib/scry_2_web/live/drafts_helpers.ex` by extracting any `if`/`case`/`cond`/`Enum` pipelines in `drafts_live.ex` (pack/pick formatting, P1P1 labels) + `drafts_helpers_test.exs`.
- Create `lib/scry_2_web/live/settings_helpers.ex` + `settings_helpers_test.exs` (TOML path validation label, detailed-logs status row).
- Add LiveView mount/patch/event integration tests (not HTML asserts per project rules) for `DashboardLive`, `MatchesLive`, `CardsLive`, `DraftsLive`, `SettingsLive`.

---

## 6. Worker test  — **MISSING**

`lib/scry_2/workers/cards_refresh_worker.ex` exists but `test/scry_2/workers/cards_refresh_worker_test.exs` does not. Required by project test policy. Use `Oban.Testing` + `Req.Test` stub; verify `unique: [period: 60]` behavior, successful run path, and error path.

---

## 7. End-to-end verification  — **NOT RUN**

None of the verification steps in `RECOVERED_PLAN.md` §"Verification" §§1–8 have been executed against real systems (only `mix precommit`-level checks have run). Work through them in order once items 1–5 are in:

1. `mix precommit` — zero warnings, all tests pass.
2. `mix ecto.setup` — confirm `~/.local/share/scry_2/scry_2.db` exists with all tables via `sqlite3 ... ".schema"`.
3. `Scry2.Cards.Lands17Importer.run()` live — confirm > 20 000 rows and spot-check named cards in `/cards`.
4. Watcher against real `Player.log` — launch MTGA, play a match, verify `mtga_logs_events` rows appear + `/matches` shows the finished match.
5. Oban scheduled refresh — exercise the "Refresh cards now" button, confirm job state transitions + `cards_cards.updated_at` moves.
6. Restart durability — kill the server mid-session, confirm `mtga_logs_cursor` has current offset, restart, confirm no duplicate ingestion.
7. Detailed-logs warning path — point the watcher at a log file without detailed logs enabled, confirm the dashboard banner renders.
8. `mix test --cover` — ≥80% coverage on pure function modules, ≥60% overall.

---

## 8. Open risks still to resolve

Carried from `RECOVERED_PLAN.md` §"Open Questions / Risks Flagged":

1. **`arena_id` availability in 17lands `cards.csv`** — verify on first real import. Blocks item 4 above (see §4).
2. **MTGA log format stability** — monitored via `raw_json` in `mtga_logs_events`; no action now, but reparse tooling will eventually be needed.
3. **Oban + SQLite cron** — verify `Oban.Engines.Lite` cron scheduling actually fires in dev. Fallback is a plain GenServer timer.
4. **`file_system` on Flatpak paths** — inotify should work on Proton-flatpak dirs because they're ext4 under `$HOME`. Verify on first run; fall back to polling `poll_interval_ms` if broken.
5. **Fixture sourcing** — prerequisite for item 2 + item 3. Ask the user.
