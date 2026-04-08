# Scry2 — Remaining Work

When picking up any item, invoke the relevant thinking skill first (see `CLAUDE.md` → *Skills-First Development*).

---

## Completed

- **Event ingestion coverage (§0)** — 10 domain event types wired, 116+ events from 6,554 raw events. Zero unrecognized event types in discovery registry (ADR-020). All observed MTGA types either handled or explicitly ignored.
- **Component-aware logging + Console drawer (§1)** — full stack live with Erlang `:logger` handler, ring buffer, filter persistence, Guake-style drawer.
- **Real MTGA log fixtures + parser tests (§2)** — 8 fixtures captured and anonymized per ADR-021. Parser handles Format A (inline), Format B (multiline), and Format A response (three-line `<==` pattern).
- **Event-sourced ingestion pipeline (§3)** — MtgaLogIngestion → Events (IdentifyDomainEvents + IngestRawEvents with match_context state per ADR-022) → Matches/Drafts projectors. Rebuild tooling: `replay_projections!/0` and `retranslate_from_raw!/0`.
- **Domain-purpose naming (ADR-019)** — all modules named for what they do, not what pattern they implement.
- **Complete event coverage (ADR-020)** — discovery registry + dashboard widget for unrecognized types.
- **Fixture capture policy (ADR-021)** — every new event type gets a real anonymized fixture.
- **Stateful match correlation (ADR-022)** — IngestRawEvents tracks current_match_id + current_game_number for tagging in-game events.

### Domain events wired

| Domain Event | Source | Projected? |
|---|---|---|
| `%MatchCreated{}` | MatchGameRoomStateChangedEvent (Playing) | Yes → `matches_matches` |
| `%MatchCompleted{}` | MatchGameRoomStateChangedEvent (MatchCompleted) | Yes → `matches_matches` |
| `%GameCompleted{}` | GreToClientEvent → GameStateMessage (GameComplete) | Yes → `matches_games` |
| `%DeckSubmitted{}` | GreToClientEvent → ConnectResp | Yes → `matches_deck_submissions` |
| `%DieRollCompleted{}` | GreToClientEvent → DieRollResultsResp | No projection yet |
| `%MulliganOffered{}` | GreToClientEvent → MulliganReq | No projection yet |
| `%DraftStarted{}` | BotDraftDraftStatus | Yes → `drafts_drafts` |
| `%DraftPickMade{}` | BotDraftDraftPick | Yes → `drafts_picks` |
| `%RankSnapshot{}` | RankGetSeasonAndRankDetails / RankGetCombinedRankInfo | No projection yet |
| `%SessionStarted{}` | AuthenticateResponse | No projection yet |

---

## Next priorities

### 1. Self-user-id auto-detection

`SessionStarted` domain events carry `client_id` — the user's Wizards ID. Use this to eliminate the manual `mtga_self_user_id` config entry. On first `%SessionStarted{}`, store the `client_id` in Settings and use it for all subsequent translations. Currently falls back to `systemSeatId: 1`.

### 2. Derived events — on_play determination

`%DieRollCompleted{}` tells us who goes first in game 1 (higher roll). For games 2+, the loser of the previous game chooses. A domain-level mechanism (in the Matches context, watching domain events) should emit derived `on_play` state by correlating DieRoll + GameCompleted sequences. This would populate `matches_games.on_play`.

### 3. Projections for new event types

DieRollCompleted, MulliganOffered, RankSnapshot, and SessionStarted have no projection tables yet. Decide which need dedicated tables vs which are consumed via the domain event log directly:
- **RankSnapshot** → likely needs a `ranks_snapshots` table for trend display
- **DieRollCompleted** → could enrich `matches_games.on_play` via derived event (see §2)
- **MulliganOffered** → could be counted per game in projection, or stored individually
- **SessionStarted** → feeds Settings (self_user_id), no dedicated table needed

### 4. Scryfall `arena_id` backfill

17lands `cards.csv` does not include MTGA's `arena_id`. A `Scry2.Cards.ScryfallBackfill` module needs to pull bulk data from Scryfall API, cross-reference by `(set_code, collector_number)`, and populate `cards_cards.arena_id`. This is the only way log events can be joined to card metadata. Verify first whether 17lands has added `arena_id` to their CSV since last check.

### 5. LiveView helpers + tests

ADR-013 requires extracted pure helpers with `async: true` tests for every LiveView. Status:

| LiveView | Helpers | Integration test |
|---|---|---|
| DashboardLive | `dashboard_helpers.ex` ✓ | missing |
| MatchesLive | `matches_helpers.ex` ✓ | missing |
| CardsLive | `cards_helpers.ex` ✓ | missing |
| DraftsLive | missing | missing |
| SettingsLive | missing | missing |

### 6. Worker test

`Scry2.Workers.PeriodicallyUpdateCards` has no test. Required by project test policy. Use `Oban.Testing` + `Req.Test` stub.

### 7. End-to-end verification

Run through the full verification checklist against real systems:
1. `mix precommit` — zero warnings, all tests pass ✓
2. `mix ecto.setup` — confirm database exists with all tables
3. `Scry2.Cards.SeventeenLands.run()` live — confirm > 20,000 card rows
4. Watcher against real `Player.log` — play a match, verify events flow end-to-end ✓
5. Oban scheduled refresh — exercise the refresh button
6. Restart durability — kill server, confirm cursor persists, no duplicate ingestion
7. Detailed-logs warning path — point at log without detailed logs, confirm dashboard banner

---

## Open risks

1. **MTGA log format stability** — monitored via `raw_json` preservation + reparse tooling.
2. **Oban + SQLite cron** — verify `Oban.Engines.Lite` cron scheduling actually fires in dev.
3. **`file_system` on Flatpak paths** — verify inotify works on Proton-flatpak dirs.
4. **Draft ID correlation** — `BotDraftDraftPick` events use `EventName` as `mtga_draft_id`. Multiple drafts of the same format would collide. Acceptable for personal MVP; needs session tracking for correctness.

---

## Game replay data (future — significant work)

The MTGA log contains the complete in-game action history inside
`GreToClientEvent` (289 `GameStateMessage` entries per session) and
`ClientToGremessage` (player actions). Combined, these reconstruct
every turn of every game: cards drawn, spells cast, attacks, blocks,
life total changes, zone transitions.

### Server → Client (GameStateMessage differential state)

- **289 GameStateMessages** — every game state change (zones, objects, counters, annotations)
- **ActionsAvailableReq (36)** — what the player can do at each priority pass
- **TimerStateMessage (35)** — chess clock state, timeout tracking

### Client → Server (player actions)

- **PerformActionResp (204)** — cards played, abilities activated, lands dropped
- **SubmitAttackersReq (33)** — which creatures attacked
- **SelectTargetsResp (31)** — spell/ability target choices
- **DeclareBlockersResp (11)** — block assignments
- **AssignDamageResp (4)** — damage assignment order
- **CastingTimeOptionsResp (13)** — mana payment choices

### What this enables

- Full game replay (17lands-style)
- Per-turn card draw / play sequence
- Combat analytics (attack/block patterns)
- Mana efficiency tracking
- Decision tree analysis

### Prerequisites

- ADR-025 cumulative game state is the foundation — already implemented
- Need to extend `match_context` to maintain full zone state across GameStateMessages
- Need to define domain events for turns, spells cast, combat phases
- `diffDeletedInstanceIds` handling needed for proper zone tracking
