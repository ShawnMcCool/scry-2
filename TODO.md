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

## 3. Ingester persistence logic  — **PARTIAL**

### Done in 2026-04-05 session (thin slice)

End-to-end pipeline is wired through for match creation:

- `Scry2.MtgaLogs.get_event!/1` added so ingesters can load raw events without reaching into `Repo` directly.
- `Scry2.Matches.upsert_game!/1` replaces the old `insert_game!` — upserts by `(match_id, game_number)` composite unique index. ADR-016 compliance. (`Scry2.Matches.upsert_match!/1` and `Scry2.Matches.upsert_deck_submission!/1` were already idempotent.)
- `Scry2.Matches.EventMapper` — pure module, one function per event type. Currently handles `MatchGameRoomStateChangedEvent` with state=Playing: extracts `mtga_match_id`, `event_name`, `opponent_screen_name`, `started_at`. MatchCompleted returns `:ignore` (handled in follow-up below).
- `Scry2.Matches.Ingester` — claimed types rewritten to `["MatchGameRoomStateChangedEvent"]`, dispatch wired through `EventMapper` → `Matches.upsert_match!`. Try/rescue with `MtgaLogs.mark_error!/2` on failure so malformed payloads never crash the GenServer.
- `Scry2.Drafts.Ingester` — empty `@claimed_types` (waiting for real draft fixtures) but structurally mirrors the matches ingester with error handling in place.
- Configuration: `mtga_self_user_id` key added to `Scry2.Config` + documented in `defaults/scry_2.toml`. Used by the mapper to distinguish self from opponent in `reservedPlayers[]`. Falls back to `systemSeatId: 1` when nil.
- Tests: 5 integration tests (`test/scry_2/matches/ingester_test.exs`) covering happy path, both Playing and MatchCompleted state handling, idempotency (replay produces one row), malformed JSON, and ignored event types. Plus 6 pure `EventMapper` tests. 185 total tests passing, zero warnings.
- **Verified end-to-end against the real Player.log**: parsed 3,941 events from the 22 MB file, 2 of which were `MatchGameRoomStateChangedEvent`, the pipeline created one row in `matches_matches` with the correct `mtga_match_id`, `event_name: "Traditional_Ladder"`, opponent screen name, and `started_at` timestamp.

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

### Match completion / final results (next-most-valuable follow-up)

`MatchGameRoomStateChangedEvent` with `stateType: "MatchGameRoomStateType_MatchCompleted"` carries:

- `finalMatchResult.matchId` — same id as the Playing-state event, ties completion to the initial row
- `finalMatchResult.matchCompletedReason` — e.g. `MatchCompletedReasonType_Success`, `MatchCompletedReasonType_TimeOut`
- `finalMatchResult.resultList` — array of per-game results AND one `MatchScope_Match` summary row with `winningTeamId` and `reason`

Work:

- Extend `EventMapper.match_attrs_from_game_room_state_changed/2` to handle both Playing and MatchCompleted states (return different attrs)
- Populate `matches_matches.ended_at`, `won` (from `winningTeamId` vs self team), `num_games` (count from `resultList`)
- Second upsert on the same `mtga_match_id` will enrich the existing row (idempotency already in place)
- Test fixture already committed (`match_game_room_state_changed_completed.log`)

### Per-game results (games table)

`GreToClientEvent.greToClientMessages[]` includes `type: "GREMessageType_GameStateMessage"` entries carrying:

- `gameStateMessage.gameInfo.matchID`
- `gameStateMessage.gameInfo.gameNumber`
- `gameStateMessage.gameInfo.matchState` (`MatchState_GameInProgress`, `MatchState_GameComplete`)
- `gameStateMessage.gameInfo.results[].winningTeamId` — per-game winner
- `gameStateMessage.players[]` carries mulligan count, turn number, controllerSeatId

Work:

- Dedicated `Scry2.MtgaLogs.GreMessageParser` pure module that takes a decoded `greToClientEvent` payload and returns a list of normalized `%GreMessage{}` structs (ConnectResp, GameStateMessage, DieRollResultsResp, ChooseStartingPlayerReq, etc.). Single place to version-gate the GRE protocol.
- Map GameStateMessage → `Scry2.Matches.upsert_game!` attrs via a new EventMapper function
- Track mulligans, turn count, on-play from the first GameStateMessage with `matchState: MatchState_GameInProgress`
- Track game winner from `gameInfo.results[].winningTeamId` when `matchState: MatchState_GameComplete`

### Deck submissions

`GreToClientEvent.greToClientMessages[]` with `type: "GREMessageType_ConnectResp"` carries:

- `connectResp.deckMessage.deckCards` — flat array of grpIds (aka arena_ids), one entry per copy
- `connectResp.deckMessage.sideboardCards` — same shape

Work:

- Transform flat array → `%{"cards" => [%{"arena_id" => ..., "count" => ...}]}` (the existing `matches_deck_submissions.main_deck` format)
- `mtga_deck_id` derivation: not in the ConnectResp directly; options are (a) use `matchID` + `gameNumber: 1` as a synthetic key, (b) cross-reference with `DeckUpsertDeckV2` or `EventSetDeckV2` lobby events that fire before a match to get the real deck id
- Alternative source: `DeckUpsertDeckV2` / `EventSetDeckV2` events carry the user's deck directly in a simpler structure, but only for the local player — opponent decks only come from GRE ConnectResp
- Test fixture already committed (`gre_to_client_event_connect_resp.log`)

### Drafts (entirely new, blocked on fixtures)

The user's current Player.log has no draft activity. Unblock by running a draft with detailed logs enabled, then:

- Collect fixtures for: pack presentation (the moment cards appear for picking), pick submission, draft completion
- Expected event types TBD — likely embedded in `GreToClientEvent` for draft state, plus separate lobby events. Until we see the real shape, don't guess.
- Once fixtures exist, implement `Scry2.Drafts.EventMapper` mirroring `Scry2.Matches.EventMapper`
- Wire `Scry2.Drafts.Ingester.@claimed_types` (currently empty), add dispatch to `Drafts.upsert_draft!/1` and `Drafts.upsert_pick!/1`

### Player & opponent rank extraction

Rank data is in separate `RankGetCombinedRankInfo` and `RankGetSeasonAndRankDetails` events (API lobby events, Format A). They report the player's own rank only. Opponent rank may be in `reservedPlayers[]` on the match event — needs verification with real sample. Populate `matches_matches.player_rank` and `opponent_rank` once the payload shape is confirmed.

### Event format labels

`EventJoin.request.EventName` is a double-encoded JSON string containing an event id like `"Traditional_Ladder"`, `"PremierDraft_LCI_20260401"`, `"Constructed_BO1_2026Q2"`. We currently copy this value verbatim into `matches_matches.event_name`. Follow-up: maintain a mapping from raw event id → human-readable label (`"Traditional Ladder"`, `"Lost Caverns Premier Draft"`) for dashboard display. Populate `matches_matches.format` as a separate coarse bucket: `constructed`, `draft`, `limited`, `brawl`, etc.

### Color identity derivation

`matches_games.main_colors` / `splash_colors` are in the schema but unpopulated. Derive from deck submissions + `cards_cards.color_identity` once the Scryfall `arena_id` backfill (Item 4 below) is complete. Blocked on that work.

### Timezone handling for log timestamps

`parse_timestamp/1` in `event_parser.ex` currently tags all timestamps as `"Etc/UTC"` — MTGA writes them as local time with no zone annotation, so there's drift. Fix by either sniffing the OS timezone at startup or adding a `mtga_log_timezone = "auto"` config key. Ordering/relative comparisons work correctly regardless; only absolute display timestamps are wrong.

### Self-user-id auto-detection

Currently the user can set `mtga_logs.self_user_id` in `config.toml`, otherwise the mapper falls back to `systemSeatId: 1`. Better: parse the `authenticateResponse` block that appears at session start (visible on line ~300 of Player.log — `"clientId": "D0FECB2AF1E7FE24"`) and cache it in a lightweight GenServer or ETS table. Removes the need for user configuration.

### Inventory / collection tracking (new feature, not in current schema)

Collection snapshots come via `PlayerInventoryGetPlayerCards` / `InventoryUpdate` — but those names were speculative from the bootstrap and have not been observed in the user's log. Needs discovery: play a session that triggers inventory refresh, search the log for events carrying card counts. If found, design a new `Scry2.Inventory` bounded context with tables for `inventory_cards` and `inventory_snapshots`, mirroring the pipeline structure. Enables collection tracker / missing wildcards UI.

### GRE stream parsing infrastructure (foundational for games + decks)

GRE messages are nested 4–5 levels deep inside `greToClientEvent.greToClientMessages[]`. Each message has a `type: GREMessageType_*` discriminator. Extract a dedicated `Scry2.MtgaLogs.GreMessageParser` pure module that takes a raw `greToClientEvent` payload and returns a list of normalized `%GreMessage{type, msg_id, payload}` structs. Single place to version-gate MTGA's GRE protocol changes. All game/deck follow-ups depend on this.

### Reprocess tooling

Add `Scry2.MtgaLogs.reprocess_unprocessed/1` — iterates `list_unprocessed/1` in batches and re-broadcasts `{:event, id, type}` to the topic so ingesters re-process. Useful when parser/mapper changes land and historical data needs re-ingestion. Could be exposed as a button on the Settings page or an Oban job.

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
