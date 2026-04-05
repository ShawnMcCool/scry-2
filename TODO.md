# Scry2 Bootstrap — Remaining Work

Distilled from `RECOVERED_PLAN.md` against the state of commit `caf8d36 feat: bootstrap scry_2 Phoenix backend for MTGA analytics`. The bootstrap commit covers most of Phases A–G (generator, config/TOML, migrations, schemas, contexts, watcher, parser, ingesters, importer, worker, five LiveViews, decision records 001–016). The items below are gaps that remain.

When picking up any of these, invoke the relevant thinking skill first (see `CLAUDE.md` → *Skills-First Development*).

---

## 1. Component-aware logging + Console drawer  — **DONE** (2026-04-05)

Shipped in commit `f72aa1f4 feat: component-tagged logging with console drawer`. The full stack is live:

- `Scry2.Log` macros (`info/2`, `warning/2`, `error/2`) with component tags
- `Scry2.Console` bounded context (buffer, filter, handler, view, entry)
- Erlang `:logger` handler wired from `application.ex`
- Guake-style sticky drawer mounted in every LiveView via `Layouts.console_mount`
- Full-page `/console` route
- Filter state + buffer size persisted to `Settings.Entry` with 2-second debounce
- All `Logger.*` call sites swapped to `Scry2.Log.*`
- Backtick (`` ` ``) key binding wired in `assets/js/app.js`

---

## 2. Real MTGA log fixtures + append-only parser tests  — **PARTIAL**

### Done in 2026-04-05 session

Four real fixtures mined from the user's Player.log and committed under `test/fixtures/mtga_logs/`, with opponent PII (playerName, Wizards userId) anonymized to `Opponent1` / `OPPONENT_USER_ID_1`:

- `event_join.log` — Format A inline request (regression baseline)
- `match_game_room_state_changed_playing.log` — Format B match creation
- `match_game_room_state_changed_completed.log` — Format B match finalization
- `gre_to_client_event_connect_resp.log` — Format B GRE stream with deck info (fixture only, mapper wiring deferred)

Corresponding append-only test cases in `test/scry_2/mtga_logs/event_parser_test.exs`. Existing synthetic tests retained per ADR-010.

### Parser extended for Format B

Original parser regex only handled `[UnityCrossThreadLogger]==> EventType` headers (Format A). Real Player.log uses two distinct header shapes — the second (`[UnityCrossThreadLogger]M/D/YYYY H:MM:SS AM/PM: <text>: EventType`) carries all actual match/game activity and was silently skipped. Parser rewritten with plain pattern matching on binary prefixes (`parse_header/1` in `lib/scry_2/mtga_logs/event_parser.ex`) to handle both formats. `parse_timestamp/1` now parses the 12-hour AM/PM format into a `%DateTime{}` instead of returning nil. Also fixed a scanning bug where `find_event_starts` was finding only ~0.6% of headers due to mixing grapheme-based and byte-based indexing; rewrote with `:binary.matches/2` for O(n) correctness.

### Still to do

Fixture expansion is append-only — grow organically as new edge cases surface:

- Per-event-type fixtures for every real type observed in Player.log: `ClientToGreuimessage` (1200+ occurrences, likely an MTGA-internal UI message channel), `ClientToGremessage`, `AuthenticateResponse`, `DeckUpsertDeckV2`, `EventSetDeckV2`, `EventEnterPairing`, `EventGetCoursesV2`, `EventGetActiveMatches`, `DeckGetDeckSummariesV2`, `RankGetCombinedRankInfo`, `RankGetSeasonAndRankDetails`, `GraphGetGraphState`, `QuestGetQuests`, `PeriodicRewardsGetStatus`, `StartHook`, `GetFormats`
- Draft events (blocked — user's current log has no draft activity; run a draft to generate fixtures)
- `GameStateMessage` substructures inside `GreToClientEvent` for game-level results

---

## 3. Ingestion + projection pipeline  — **PARTIAL** (event-sourced)

### Done in 2026-04-05 sessions

**Thin slice (first session):** direct mapper-based path for match creation. `MtgaLogs.get_event!/1`, `Matches.upsert_game!/1`, ingester error handling, `Scry2.Matches.EventMapper`, ingester dispatch wired, `mtga_self_user_id` config, 185 tests.

**Event sourcing refactor (second session):** retrofitted the thin slice into an event-sourced architecture per ADR-017 and ADR-018. Both match creation AND completion now work end-to-end.

- **New bounded context** `Scry2.Events` (table: `domain_events`, append-only): holds the domain event log plus the Translator (anti-corruption layer), IngestionWorker, and the `Event` protocol.
- **Domain event catalog** under `lib/scry_2/events/`: `MatchCreated`, `MatchCompleted` (both wired); `GameCompleted`, `DeckSubmitted`, `DraftStarted`, `DraftPickMade` (struct + protocol defined, no translator clause yet).
- **`Scry2.Events.Translator`** (pipeline stage 07, pure) — the ONLY place MTGA wire format is understood. Consumes `%MtgaLogs.EventRecord{}` + `self_user_id`, returns list of domain event structs. Handles `MatchGameRoomStateChangedEvent` with `Playing` → `%MatchCreated{}` and `MatchCompleted` → `%MatchCompleted{}` (including win/loss derivation from `finalMatchResult.resultList`).
- **`Scry2.Events.IngestionWorker`** (pipeline stage 08) — GenServer, subscribes to `mtga_logs:events`, runs Translator, persists via `Events.append!/2`, marks raw events processed. Single subscriber of the raw topic.
- **Projectors** — `Scry2.Matches.Projector` and `Scry2.Drafts.Projector` (pipeline stage 09) — GenServers subscribing to `domain:events`. Matches projector handles `%MatchCreated{}` and `%MatchCompleted{}` via `Matches.upsert_match!/1`. Drafts projector has empty `@claimed_slugs` pending draft fixtures.
- **Rebuild tooling** — `Scry2.Events.replay_projections!/0` (drop projections, replay domain event log) and `Scry2.Events.retranslate_from_raw!/0` (drop domain events, re-run translator from raw log).
- **Deleted** — `Scry2.Matches.EventMapper`, `Scry2.Matches.Ingester`, `Scry2.Drafts.Ingester` and their tests. Replaced by Translator + Projector infrastructure.
- **ADRs** — ADR-017 (event sourcing core architecture), ADR-018 (anti-corruption layer).
- **Tests** — 206 total (up from 185 pre-refactor). 6 new test files replacing 2 deleted. End-to-end path verified against real Player.log.

### See "Match ingestion follow-ups" below for everything still to do

---

## 3b. Match ingestion follow-ups

Everything deferred from the thin slice. Ordered roughly by impact. Each bullet is a future session candidate.

### Discovery notes (what the real log contains)

- MTGA Player.log uses **two header formats**:
  - **Format A**: `[UnityCrossThreadLogger]==> EventType {inline JSON}` — lobby/API events. Request JSON on same line, response JSON on subsequent `<==` line (without the `[UnityCrossThreadLogger]` prefix).
  - **Format B**: `[UnityCrossThreadLogger]M/D/YYYY H:MM:SS AM/PM: <direction text>: EventType` followed by JSON body on the next line. Carries match/game lifecycle via `MatchGameRoomStateChangedEvent`, `GreToClientEvent`, `ClientToGremessage`, `ClientToGreuimessage`.
- Real top-level event types observed: `GreToClientEvent` (2300+), `ClientToGreuimessage` (1200+), `ClientToGremessage` (360+), `GraphGetGraphState`, `MatchGameRoomStateChangedEvent` (2 per match), plus the usual lobby set.
- The original speculative list from the bootstrap plan (`EventMatchCreated`, `MatchStart`, `MatchEnd`, `MatchCompleted`, `GameComplete`, `EventDeckSubmit`, `EventPayEntry`, `DraftMakePick`, `DraftPack`, `DraftNotify`, `EventGetPlayerCourse`, `PlayerInventoryGetPlayerCards`, `InventoryUpdate`) **does not exist** in observed logs. Those names were guesses and should not appear in future code.

### Pattern for adding a new domain event type

With the event-sourced architecture (ADR-017, ADR-018), every follow-up below follows the same recipe:

1. **Define the struct** — `lib/scry_2/events/<name>.ex` with `@enforce_keys`, `@type t`, and `defimpl Scry2.Events.Event` (type_slug + mtga_timestamp). Stub structs for `GameCompleted`, `DeckSubmitted`, `DraftStarted`, `DraftPickMade` already exist.
2. **Add a Translator clause** — in `lib/scry_2/events/translator.ex`, add a `translate/2` head for the relevant raw MTGA event type that produces the struct. Use real fixtures from `test/fixtures/mtga_logs/` (ADR-010).
3. **Add a rehydration clause** — in `Scry2.Events.get/1` to deserialize the persisted payload back into the struct.
4. **Add a projector handler** — in the relevant projector (`Matches.Projector`, `Drafts.Projector`, or a new one) pattern-match on the struct type and call the appropriate upsert. Add the slug to `@claimed_slugs`.
5. **Test the slice** — struct test, translator test with fixture, projector test, end-to-end ingestion worker test.

### Match completion / final results — **DONE** (event-sourced refactor session)

`%Scry2.Events.MatchCompleted{}` wired end-to-end. Translator produces it from `MatchGameRoomStateChangedEvent` with `stateType: MatchCompleted`, computing `won` from `finalMatchResult.resultList[].winningTeamId` vs the self team (from `reservedPlayers[]`). Projector enriches the existing `matches_matches` row via `upsert_match!/1` (idempotent by `mtga_match_id`).

### Per-game results (games table)

Domain event: `%Scry2.Events.GameCompleted{}` — struct already defined under `lib/scry_2/events/game_completed.ex`, slug `"game_completed"`.

Data source: `GreToClientEvent.greToClientMessages[]` with `type: "GREMessageType_GameStateMessage"`:

- `gameStateMessage.gameInfo.matchID`
- `gameStateMessage.gameInfo.gameNumber`
- `gameStateMessage.gameInfo.matchState` (`MatchState_GameInProgress`, `MatchState_GameComplete`)
- `gameStateMessage.gameInfo.results[].winningTeamId` — per-game winner
- `gameStateMessage.players[]` carries mulligan count, turn number, controllerSeatId

Work:

- Add `Scry2.Events.GreMessageParser` helper (pure) that normalizes the nested `greToClientEvent.greToClientMessages[]` structure into a flat list of typed messages (ConnectResp, GameStateMessage, DieRollResultsResp, etc.). Shared infrastructure for per-game AND deck-submission work below.
- Translator clause for raw `GreToClientEvent`: run through GreMessageParser, emit `%GameCompleted{}` for each GameStateMessage with `matchState: MatchState_GameComplete`.
- Add `game_completed` handler to `Matches.Projector`, call `Matches.upsert_game!/1`.
- Real fixture: mine a game-complete GRE message from Player.log (append-only per ADR-010).

### Deck submissions

Domain event: `%Scry2.Events.DeckSubmitted{}` — struct already defined under `lib/scry_2/events/deck_submitted.ex`, slug `"deck_submitted"`.

Data source: `GreToClientEvent.greToClientMessages[]` with `type: "GREMessageType_ConnectResp"`:

- `connectResp.deckMessage.deckCards` — flat array of grpIds (aka arena_ids), one entry per copy
- `connectResp.deckMessage.sideboardCards` — same shape

Work:

- Translator clause for raw `GreToClientEvent`: find ConnectResp messages, transform flat arrays into `[%{arena_id: _, count: _}]` aggregated shape, emit `%DeckSubmitted{}`.
- `mtga_deck_id` derivation: not in the ConnectResp directly; options are (a) synthetic key `matchID + "-g1"`, (b) cross-reference with `DeckUpsertDeckV2`/`EventSetDeckV2` lobby events fired before the match.
- Add `deck_submitted` handler to `Matches.Projector`, call `Matches.upsert_deck_submission!/1`.
- Real fixture already committed (`gre_to_client_event_connect_resp.log`).

### Drafts (entirely new, blocked on fixtures)

Domain events: `%Scry2.Events.DraftStarted{}` and `%Scry2.Events.DraftPickMade{}` — structs already defined under `lib/scry_2/events/`, slugs `"draft_started"` and `"draft_pick_made"`.

The user's current Player.log has no draft activity. Unblock by running a draft with detailed logs enabled, then:

- Collect fixtures for: draft start notification, pack presentation, pick submission, draft completion.
- Expected raw event types TBD until we see real data — likely embedded in `GreToClientEvent` for draft state plus separate lobby events.
- Add Translator clauses that produce `%DraftStarted{}` and `%DraftPickMade{}`.
- Wire `Scry2.Drafts.Projector.@claimed_slugs` (currently empty), add handlers that call `Drafts.upsert_draft!/1` and `Drafts.upsert_pick!/1`.

### Player & opponent rank extraction

Rank data is in separate `RankGetCombinedRankInfo` and `RankGetSeasonAndRankDetails` events (API lobby events, Format A). They report the player's own rank only. Opponent rank may be in `reservedPlayers[]` on the match event — needs verification with real sample. Populate `matches_matches.player_rank` and `opponent_rank` once the payload shape is confirmed.

### Event format labels

`EventJoin.request.EventName` is a double-encoded JSON string containing an event id like `"Traditional_Ladder"`, `"PremierDraft_LCI_20260401"`, `"Constructed_BO1_2026Q2"`. We currently copy this value verbatim into `matches_matches.event_name`. Follow-up: maintain a mapping from raw event id → human-readable label (`"Traditional Ladder"`, `"Lost Caverns Premier Draft"`) for dashboard display. Populate `matches_matches.format` as a separate coarse bucket: `constructed`, `draft`, `limited`, `brawl`, etc.

### Color identity derivation

`matches_games.main_colors` / `splash_colors` are in the schema but unpopulated. Derive from deck submissions + `cards_cards.color_identity` once the Scryfall `arena_id` backfill (Item 4 below) is complete. Blocked on that work.

### Timezone handling for log timestamps

`parse_timestamp/1` in `event_parser.ex` currently tags all timestamps as `"Etc/UTC"` — MTGA writes them as local time with no zone annotation, so there's drift. Fix by either sniffing the OS timezone at startup or adding a `mtga_log_timezone = "auto"` config key. Ordering/relative comparisons work correctly regardless; only absolute display timestamps are wrong.

### Self-user-id auto-detection

Currently the user can set `mtga_logs.self_user_id` in `config.toml`, otherwise the Translator falls back to `systemSeatId: 1`. Better: the Translator emits a synthetic `%Scry2.Events.AuthenticateResponded{client_id: ...}` event on session start, the `IngestionWorker` stores the current client_id in a lightweight ETS table or GenServer, and the Translator reads from there instead of Config on subsequent events. Removes the need for user configuration and handles the case where the user has multiple MTGA accounts.

### Inventory / collection tracking (new feature, not in current schema)

Collection snapshots come via `PlayerInventoryGetPlayerCards` / `InventoryUpdate` — but those names were speculative from the bootstrap and have not been observed in the user's log. Needs discovery: play a session that triggers inventory refresh, search the log for events carrying card counts. If found, design a new `Scry2.Inventory` bounded context with tables for `inventory_cards` and `inventory_snapshots`, mirroring the pipeline structure. Enables collection tracker / missing wildcards UI.

### GRE stream parsing infrastructure (foundational for games + decks)

GRE messages are nested 4–5 levels deep inside `greToClientEvent.greToClientMessages[]`. Each message has a `type: GREMessageType_*` discriminator. Extract a dedicated `Scry2.Events.GreMessageParser` pure module (lives inside the Events context since it's part of the anti-corruption boundary) that takes a raw `greToClientEvent` payload and returns a list of normalized `%GreMessage{type, msg_id, payload}` helper structs. Single place to version-gate MTGA's GRE protocol changes. All game-completed and deck-submission follow-ups depend on this.

Note: `%GreMessage{}` is a private parsing helper, NOT a domain event. It doesn't implement `Scry2.Events.Event` and is never persisted. It just exists to untangle the deep nesting before the Translator builds real domain events from it.

### Reprocess / rebuild tooling (partially DONE)

`Scry2.Events.replay_projections!/0` and `Scry2.Events.retranslate_from_raw!/0` already exist from the refactor session. Still to do: expose them as buttons on the Settings page, or trigger from an Oban job, so the user can rebuild projections without dropping into an IEx shell.

### Parser edge case: `<==` response lines

API response lines in the real log are structured as THREE separate lines:
```
[UnityCrossThreadLogger]4/5/2026 7:17:59 PM        # header with just a timestamp, no type
<== EventJoin(uuid)                                # response marker, no UCTL prefix
{JSON body}                                        # response payload
```

The current parser correctly skips the middle line (bare timestamp with no `: ` split) but never associates the `<==` response line with an event. These responses sometimes carry richer data than the request. Future work: detect the pattern and emit a synthetic event tying the response to the preceding request by transaction id.

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
