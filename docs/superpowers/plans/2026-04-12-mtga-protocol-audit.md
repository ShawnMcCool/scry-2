# MTGA Protocol Correctness Audit — Plan

## Context

During the deck matches tab redesign (2026-04-12), we discovered two data integrity bugs caused by incorrect MTGA protocol handling:

1. **Per-game `won` values were inverted** for ~40% of BO3 matches. Root causes: (a) hardcoded seat 1 as "self" when the player alternates seats, and (b) the GRE reports wrong outcomes for conceded games.
2. **Deck format was set to event-type strings** like "DirectGame" instead of the actual format ("Standard").

These bugs were silent — tests passed, no errors logged, but the data was wrong. The fixes revealed more hardcoded seat assumptions elsewhere in the codebase that haven't been fixed yet. This audit will systematically identify and fix all remaining protocol correctness issues.

## Goal

Verify that every perspective-sensitive field in the MTGA ingestion pipeline correctly identifies which player is "self" and which is "opponent" — regardless of which seat the player occupies.

## What "perspective-sensitive" means

Any field whose value depends on knowing which player is the local user:
- `won` / `lost` — did THIS player win?
- `on_play` — did THIS player go first?
- `num_mulligans` / `opponent_num_mulligans` — whose mulligan count?
- `self_life_total` / `opponent_life_total` — whose life?
- `self_roll` / `opponent_roll` — whose die roll?
- `self_goes_first` / `chose_play` — did THIS player choose?
- `seat_id` — which seat is THIS player in?

## MTGA protocol facts (learned the hard way)

These are documented in `IdentifyDomainEvents` @moduledoc "MTGA protocol pitfalls":

1. **Player seat alternates between matches.** The player is NOT always seat 1. Each match assigns seats independently.

2. **Two subsystems, two seat/team mappings:**
   - `MatchGameRoomStateChangedEvent` → matchmaking layer. Has `reservedPlayers[]` with `userId` → `systemSeatId` → `teamId`. This is the authoritative source for player identity.
   - `GreToClientEvent` → GRE (Game Rule Engine). Has `systemSeatIds` per message and `players[].systemSeatNumber` in GameStateMessages. The `systemSeatIds[0]` on each message tells us which seat the message is addressed to. Since `GreToClientEvent` is the player's client feed, this IS the player's seat.

3. **GRE game results are wrong for conceded games.** The GRE's `GameStateMessage` with `MatchState_GameComplete` reports the last game state before concession. The matchmaking layer's `finalMatchResult.resultList[]` is authoritative.

4. **Team IDs may differ between GRE and matchmaking.** Never compare `teamId` across the two subsystems. Within each, team IDs are internally consistent.

5. **`self_user_id` may be nil** before `AuthenticateResponse` arrives. All seat-dependent logic falls back to seat 1 when nil. This is correct for initial log parsing (first event in any session is auth), but fragile.

## Known bugs to fix

### Bug 1: DieRolled hardcodes seat 1

**File:** `lib/scry_2/events/identify_domain_events.ex` (die roll handler)

```elixir
self_roll_entry = Enum.find(rolls, &(&1["systemSeatId"] == 1))
opponent_roll_entry = Enum.find(rolls, &(&1["systemSeatId"] != 1))
```

When the player is seat 2, this swaps self/opponent rolls and inverts `self_goes_first`. This propagates to `IngestionState.match.on_play_for_current_game`, which is used to enrich `GameCompleted.on_play`.

**Impact:** `on_play` is wrong for every game where the player was seat 2. Every "on play" win rate stat is corrupted.

**Fix:** Extract the player's seat from the GRE message's `systemSeatIds` using `msg_seat/1`, then find self/opponent by that seat number.

### Bug 2: StartingPlayerChosen hardcodes seat 1

**File:** `lib/scry_2/events/identify_domain_events.ex` (ClientToGremessage handler)

```elixir
chose_play: seat == 1
```

Compares the seat that chose to play against hardcoded 1. When player is seat 2 and chooses play, this records `chose_play: false`.

**Impact:** Same as Bug 1 — `on_play_for_current_game` gets the wrong value for seat-2 matches.

**Fix:** Compare `seat == player_seat` where `player_seat` comes from match context's `self_seat_id`.

### Bug 3: MatchProjection doesn't correct GameCompleted values

**File:** `lib/scry_2/matches/match_projection.ex`

The `DeckProjection` now corrects per-game `won` values using `MatchCompleted.game_results` (the authoritative source). But the `MatchProjection` still trusts `GameCompleted.won` directly. This means the `matches_matches` table has inverted per-game data for conceded games.

**Fix:** Apply the same `correct_game_results` pattern in `MatchProjection.project(%MatchCompleted{})`.

### Bug 4: Deck format is nil after filtering

**File:** `lib/scry_2/events/identify_domain_events.ex` (DeckUpsertDeckV2 handler)

We now correctly filter event-type strings ("DirectGame") from the format field via `normalize_deck_format/1`. But if ALL DeckUpdated events for a deck had event-type formats, the deck's format is permanently nil.

The real format is knowable from the match's event_name (e.g., "Traditional_Ladder" → Standard constructed) or from `DeckGetDeckSummariesV2` which may carry the correct format.

**Fix:** When the deck projection processes a `MatchCreated` or `DeckSubmitted` and the deck's format is nil, infer it from the event_name using `EnrichEvents.infer_format/1`. Only set recognized constructed formats ("Standard", "Historic", etc.).

## Audit checklist

### Phase 1: Fix known bugs (test-first)

- [ ] Fix Bug 1 — DieRolled seat identification
- [ ] Fix Bug 2 — StartingPlayerChosen seat identification
- [ ] Fix Bug 3 — MatchProjection game result correction
- [ ] Fix Bug 4 — Deck format inference fallback

### Phase 2: Systematic review of all perspective-sensitive code

For each item, verify the seat/player identification is correct:

- [ ] **GameCompleted production** (`identify_domain_events.ex` ~line 1293) — uses `msg_seat/1`. Verify correct.
- [ ] **DieRolled production** (~line 1337) — BUG, hardcodes seat 1. Fix.
- [ ] **StartingPlayerChosen production** (~line 380) — BUG, hardcodes seat 1. Fix.
- [ ] **MulliganOffered production** (~line 1375) — extracts `seat_id` from message. Verify correct.
- [ ] **MatchCreated production** (~line 1109) — uses `find_self_entry(reserved, self_user_id)`. Verify correct.
- [ ] **MatchCompleted production** (~line 1148) — uses `find_self_team_id(reserved, self_user_id)`. Verify correct.
- [ ] **DeckSubmitted production** (~line 1259) — extracts seat from ConnectResp. Verify correct.
- [ ] **EnrichEvents.GameCompleted** (~line 81) — uses `on_play_for_current_game` from state. Vulnerable to Bug 1/2.
- [ ] **DeckProjection.GameCompleted** — stores `won`, `on_play`, `num_mulligans`. Verify correct after Bug 1/2 fixes.
- [ ] **DeckProjection.MatchCompleted** — corrects per-game `won`. Verify correct.
- [ ] **MatchProjection.GameCompleted** — stores `won`, `on_play`, `mulligans`. Needs Bug 3 fix.
- [ ] **MatchProjection.MatchCompleted** — stores `won`. Verify correct.
- [ ] **MulliganProjection** — uses `seat_id` from event. Verify correct.

### Phase 3: Write regression tests

Each fixed bug gets a test that:
1. Creates a match scenario where the player is seat 2
2. Verifies the perspective-sensitive fields are correct
3. Uses real MTGA log fixture data if available, otherwise synthetic

Test cases needed:
- [ ] Player is seat 2, wins match — `MatchCompleted.won` is true
- [ ] Player is seat 2, game won — `GameCompleted.won` is true
- [ ] Player is seat 2, game won by opponent concession — `GameCompleted.won` corrected to true by `MatchCompleted`
- [ ] Player is seat 2, die roll — `DieRolled.self_goes_first` is correct
- [ ] Player is seat 2, chooses play — `StartingPlayerChosen.chose_play` is true
- [ ] Player is seat 2, mulligans — `GameCompleted.num_mulligans` is the player's count, not opponent's

### Phase 4: Verify with real data

- [ ] Full reingest (`reset_all!` → restart watcher → `retranslate_all!` → `replay_projections!`)
- [ ] Verify all BO3 matches have consistent game results (no matches where `won=true` but all games show L)
- [ ] Verify `on_play` stats are reasonable (should be ~50% across many matches)
- [ ] Verify mulligan counts are reasonable (not swapped with opponent)
- [ ] Spot-check 5 specific matches against MTGA match history or 17lands replay data

### Phase 5: Document

- [ ] Update `IdentifyDomainEvents` @moduledoc with any new findings
- [ ] Add inline comments at each perspective-sensitive extraction point
- [ ] Update decision records if architectural changes were needed

## Files involved

| File | Role |
|------|------|
| `lib/scry_2/events/identify_domain_events.ex` | ACL — all MTGA protocol handling |
| `lib/scry_2/events/enrich_events.ex` | Enrichment — `on_play` from state |
| `lib/scry_2/events/ingestion_state.ex` | State machine — `on_play_for_current_game`, `self_seat_id` |
| `lib/scry_2/events/ingestion_state/match.ex` | Match context struct |
| `lib/scry_2/events/ingest_raw_events.ex` | Pipeline orchestration |
| `lib/scry_2/decks/deck_projection.ex` | Deck match results projection |
| `lib/scry_2/matches/match_projection.ex` | Match recording projection |
| `lib/scry_2/mulligans/mulligan_projection.ex` | Mulligan tracking projection |
| `lib/scry_2/events/match/game_completed.ex` | GameCompleted struct |
| `lib/scry_2/events/match/die_rolled.ex` | DieRolled struct |
| `lib/scry_2/events/deck/deck_submitted.ex` | DeckSubmitted struct (carries `self_seat_id`) |

## Verification

After all fixes:

1. `mix precommit` passes clean
2. Full reingest produces zero inverted matches
3. `on_play` win rates are roughly symmetric (within statistical noise)
4. Mulligan counts pass sanity check (player mulligans should match 17lands data for overlapping matches)
