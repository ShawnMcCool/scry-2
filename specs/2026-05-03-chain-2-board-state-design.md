# Chain 2: Opponent Board State and Revealed Cards

**Status:** Draft (2026-05-03)
**Scope:** Walker → MtgaMemory contract → persistence → match detail UI for the cards visible in each zone of each player's board during a match.
**Builds on:** Walker refactor (`refactor(walker): extract shared primitives per engineering audit`) and Chain 1 enrichment (`specs/2026-05-03-memory-observation-match-enrichment-design.md`).

---

## Problem

The MTGA event log carries the cards a player **submitted as their decklist**, but does not carry the cards an opponent **revealed during play**. Anything Thoughtseize / Duress shows, anything cast onto the stack, anything that lands on the battlefield, anything in the opponent's graveyard or exile — none of it appears in `Player.log` for the opponent (and only sparsely for the local player, where you can reconstruct it from GRE messages but at significant cost).

MTGA's running process, however, has the full per-zone card state in memory. The walker's existing `match_scene.rs` already chains through `MatchSceneManager.Instance → _gameManager → CardHolderManager → _provider → PlayerTypeMap` and returns a seat→zone→`holder_addr` map (`SeatZoneMap`). What is missing is the final hop: drilling into each `ICardHolder` to extract the cards' `BaseGrpId` (arena_id) values.

## Goal

Persist the per-(seat, zone) list of arena_ids visible in each player's zones at match wind-down, and surface "Opponent cards revealed" on the match detail page. Use the walker's existing Chain 2 traversal as the foundation; add only the holder-drill-down step in the walker; keep persistence and integration coherent with the Chain 1 precedent.

## Scope

**In scope:**

- Walker module that, given a `holder_addr`, extracts the arena_ids of cards visible in that zone.
- Battlefield-region traversal (zones split into 8 sub-regions × N stacks each).
- Generic `List<T>` reader for `List<BaseCDC>` (currently the walker has a `_size`/`_items` reader specialised for `ClientBoosterInfo`).
- New `walk_match_board/1` MtgaMemory callback returning a flat per-zone snapshot.
- New persistence tables `live_match_board_snapshots` (one-to-one with `live_state_snapshots`) and `live_match_revealed_cards` (per (seat, zone, arena_id, position)).
- `LiveState.Server` polls board state on the same tick cadence as Chain 1; persists the last successful board read at wind-down.
- Match detail page renders "Opponent revealed cards" (and "Your cards revealed" symmetrically) using the existing card display component.

**Out of scope (deliberate):**

- Per-tick history of the board state (when did opponent cast X). YAGNI v1; only the final snapshot is persisted.
- Library contents (always face-down for opponent; meaningless to capture).
- Hand contents that are NOT marked visible-in-layout (only revealed-in-hand cards like Thoughtseize targets are surfaced).
- Card-state metadata: tapped/untapped, face-down, attachments, counters. The cards-visible-in-zone slice is the v1 surface.
- Backfill of historical matches.
- Cross-match aggregation queries ("which cards has this opponent revealed historically"). Schema supports them; UI deferred.

## Architecture

```
LiveState.Server (existing, polls every 500 ms)
  ├─ walks Chain 1 (rank, screen name)                              [existing]
  └─ walks Chain 2 (board state)                                    [new]
        ├─ on each successful tick: stash last_board_snapshot        [new]
        └─ at wind-down: LiveState.record_final_board/2              [new]
              ├─ inserts live_match_board_snapshots row              [new]
              ├─ inserts live_match_revealed_cards rows              [new]
              └─ broadcasts {:final_board, %BoardSnapshot{}}         [new, future-use]
                 on live_match:board_final
```

**Key properties:**

- **Two reads per tick.** Chain 1 and Chain 2 walker calls are independent. Chain 2 returning `{:ok, nil}` (scene torn down) is treated identically to the existing Chain 1 nil case — wind down. Chain 2 walker errors are logged but do not abort the polling loop (Chain 1 carries on). The walker's read-budget caps (`limits.rs`) keep the per-tick cost bounded.
- **No subscriber.** Unlike Chain 1, Chain 2 has no pre-existing columns to merge into. The data is its own thing — a per-match attachment owned by `LiveState`. The match detail LiveView reads it directly via a public `LiveState` query. No `Matches.MergeBoardObservation` subscriber needed.
- **Last-write-wins per match.** Re-running a match (e.g., the user replays an event) is not a concern at the live-polling layer; the unique constraint on `live_match_board_snapshots.live_state_snapshot_id` covers the upsert.
- **Forward-only.** Matches that completed before this lands have no board snapshot; the UI renders nothing for them.

## Walker additions

### `walker/list_t.rs` — generic List<T>

**Status: closed by the walker refactor.** Post-refactor, `list_t.rs` already provides `read_int_list` (for `List<i32>`), `read_pointer_list` (for `List<TRef>`), plus the underlying `read_size` / `read_items_ptr` primitives. `mono_array::read_array_elements(addr, vector_offset, count, element_size, read_mem)` is parameterised on element size, so a struct-typed `List<CardLayoutData>` is three lines of caller code (read size, read items_ptr, call `read_array_elements` with `sizeof(CardLayoutData)` from the spike). No new helper required — adding one before the spike data lands would be premature abstraction.

Chain 2's actual list usage:
- `List<CardLayoutData>` (struct elements) — caller chunks the blob, no helper.
- `List<BaseCDC>` in `BattlefieldStack.AllCards` (reference elements) — `read_pointer_list` covers it.
- `List<BattlefieldStack>` (reference elements) — `read_pointer_list` covers it.

### `walker/card_holder.rs` — drill into a holder

New module. Given a `holder_addr`, returns `Vec<i32>` (the arena_ids of cards visible in that zone). Uses two paths:

**Non-battlefield zones (Hand, Graveyard, Exile, Stack, Command, CardBrowser*, etc.):**

1. Read `BaseCardHolder._previousLayoutData` — `List<CardLayoutData>` where each element is a struct (NOT a reference).
2. For each `CardLayoutData`:
   - Read `IsVisibleInLayout` (1 byte).
   - Read `Card` pointer (`BaseCDC*`).
   - Drill `Card → _model (CardDataAdapter) → _instance → BaseGrpId : i32`.
   - For Hand only, also check `FaceDownState._reasonFaceDown`; skip face-down entries.
3. Return arena_ids in layout order (preserves caster's intended ordering for revealed-hand displays).

**Battlefield zone (special):**

The battlefield holder's `Layout` exposes 8 `BattlefieldRegion` fields:

```
_localCreatureRegion, _localLandRegion, _localArtifactRegion, _localPlaneswalkerRegion,
_opponentCreatureRegion, _opponentLandRegion, _opponentArtifactRegion, _opponentPlaneswalkerRegion
```

For the per-seat output, the walker only needs the four regions matching the requested seat. Each region's `_stacksByShape` is `Dict<i32, List<BattlefieldStack>>`. For each stack, `AllCards : List<BaseCDC>` enumerates the cards in that stack. Flatten across regions and stacks; preserve stack-internal order.

**Limits:** Per-zone arena_id collection capped at `LIMITS.max_cards_per_zone` (suggest 256 — covers any plausible Day 0 boardstate). Battlefield region count capped at the 8 expected. Stack-list length capped at `LIMITS.max_stacks_per_region` (suggest 64).

### `MonoOffsets` — Chain 2 offsets

The MTGA-default offset table picks up new constants (sourced from `mtga-duress/experiments/spikes/spike16_match_manager/FINDING.md` plus a follow-up live spike for the holder/region shapes that the existing FINDING.md notes are still TBD):

- `BaseCardHolder._previousLayoutData` field offset
- `CardLayoutData` element size + `IsVisibleInLayout` / `Card` field offsets
- `BaseCDC._model` offset, `CardDataAdapter._instance` offset, `_instance.BaseGrpId` offset
- `BattlefieldCardHolder.Layout` offset
- `BattlefieldRegion._stacksByShape` offset
- `BattlefieldStack.AllCards` offset

A live spike (`bin/card_holder_spike.rs`) is part of this work — analogous to the existing `match_manager_spike.rs`. It dumps the field manifests for `BaseCardHolder`, `BattlefieldCardHolder`, `BattlefieldRegion`, `BattlefieldStack`, `BaseCDC`, `CardDataAdapter`, and the relevant subclasses. The spike's stdout output becomes the FINDING.md that constants are pinned from.

## MtgaMemory contract addition

```elixir
@type seat_zone_cards :: %{
        required(:seat_id) => integer(),
        required(:zone_id) => integer(),
        required(:arena_ids) => [integer()]
      }

@type board_snapshot :: %{
        required(:zones) => [seat_zone_cards()],
        required(:reader_version) => String.t()
      }

@callback walk_match_board(pid_int()) :: {:ok, board_snapshot() | nil} | {:error, term()}
```

`{:ok, nil}` when `MatchSceneManager.Instance` is null. `{:error, _}` for upstream walker failures. The `seat_id` and `zone_id` integers are MTGA's own enums (kept opaque to MtgaMemory; translation to symbolic names lives in Elixir under `Scry2.LiveState.SeatId` / `Scry2.LiveState.ZoneId`).

`TestBackend` gains a fixture-driven `walk_match_board` mirroring the existing `walk_match_info` test pattern (process-dictionary fixture).

## Persistence

Two new tables, both owned by the `Collection`/`LiveState` boundary (LiveState side).

```elixir
# Migration A: live_match_board_snapshots
create table(:live_match_board_snapshots) do
  add :live_state_snapshot_id, references(:live_state_snapshots, on_delete: :delete_all),
      null: false
  add :reader_version, :string, null: false
  add :captured_at, :utc_datetime_usec, null: false
  timestamps(type: :utc_datetime_usec)
end
create unique_index(:live_match_board_snapshots, [:live_state_snapshot_id])

# Migration B: live_match_revealed_cards
create table(:live_match_revealed_cards) do
  add :board_snapshot_id, references(:live_match_board_snapshots, on_delete: :delete_all),
      null: false
  add :seat_id, :integer, null: false
  add :zone_id, :integer, null: false
  add :arena_id, :integer, null: false
  add :position, :integer, null: false, default: 0
  timestamps(type: :utc_datetime_usec)
end
create index(:live_match_revealed_cards, [:board_snapshot_id])
create index(:live_match_revealed_cards, [:arena_id])  # for cross-match queries
```

Schemas: `Scry2.LiveState.BoardSnapshot` and `Scry2.LiveState.RevealedCard`.

`live_state_snapshots` is the parent. Cascading delete is symbolic — these rows are not user-deleted today, but the FK keeps the model honest.

## LiveState facade additions

```elixir
# lib/scry_2/live_state.ex
@spec record_final_board(String.t(), board_snapshot()) ::
        {:ok, BoardSnapshot.t()} | {:error, Ecto.Changeset.t()}
def record_final_board(mtga_match_id, snapshot)

@spec get_board_by_match_id(String.t()) :: BoardSnapshot.t() | nil
def get_board_by_match_id(mtga_match_id)

@spec get_revealed_cards_by_match_id(String.t()) :: [RevealedCard.t()]
def get_revealed_cards_by_match_id(mtga_match_id)
```

`record_final_board/2` looks up the existing `live_state_snapshots` row by `mtga_match_id`, creates the `BoardSnapshot` row, then bulk-inserts `RevealedCard` rows in one transaction. Returns the new `BoardSnapshot`. Broadcasts `{:final_board, snapshot}` on `live_match:board_final` after commit (gated through `Scry2.SilentMode` for replay safety, mirroring the existing pattern).

## LiveState.Server changes

```elixir
# State struct: add :last_board_snapshot field

handle_info(:poll_tick, %State{phase: :polling} = state) do
  case state.memory.walk_match_info(state.mtga_pid) do
    {:ok, nil}   -> {:noreply, wind_down(state, :scene_torn_down)}
    {:ok, snap}  ->
      LiveState.broadcast_tick(snap)
      board = case state.memory.walk_match_board(state.mtga_pid) do
        {:ok, b}        -> b               # may be nil
        {:error, _err}  -> state.last_board_snapshot   # keep last good
      end
      new_state = %{state |
        last_snapshot: snap,
        last_board_snapshot: board || state.last_board_snapshot,
        poll_timer: schedule_poll(state)
      }
      {:noreply, new_state}
    {:error, reason} -> {:noreply, wind_down(state, {:walk_error, reason})}
  end
end

defp wind_down(state, _reason) do
  cancel_timers(state)
  case LiveState.record_final(state.mtga_match_id, build_snapshot_attrs(state.last_snapshot)) do
    {:ok, _snapshot}  ->
      if state.last_board_snapshot do
        LiveState.record_final_board(state.mtga_match_id, state.last_board_snapshot)
      end
    {:error, _}       -> :ok
  end
  reset_state(state)
end
```

Chain 1 stays authoritative for the wind-down decision (its nil result is the "scene torn down" signal). Chain 2 errors are tolerated tick-by-tick — the polling loop only winds down on Chain 1 failure.

## UI surface

Match detail page (`Scry2Web.MatchesLive.show` action) gains a section rendered when `LiveState.get_board_by_match_id(mtga_match_id)` is non-nil:

```
Opponent cards revealed
  Battlefield   [card] [card] [card] ...
  Graveyard     [card] [card] ...
  Exile         [card] ...
  Hand revealed [card] (Thoughtseized turn 3)   ← v1 has no turn data; just lists
  Stack         [card]
  Command       [card] (Brawl: commander)
```

Each `[card]` is the existing `Scry2Web.Components.CardThumb` (or whichever component renders an arena_id with image + hover tooltip — confirm during implementation; this is shape, not commitment).

Symmetrical "Your cards revealed" section below it. Both sections hidden when their seat had no revealed cards in any zone.

Helpers extracted into `Scry2Web.Live.MatchBoardView` (pure functions: `group_by_zone/1`, `zone_label/1`, `seat_split/2`) per ADR-013. LiveView is thin wiring.

## Testing

- **Walker:** unit tests against `FakeMem` for the new `card_holder.rs` module, mirroring the existing `match_scene.rs` test pattern. End-to-end: `walk_match_board` returns a synthetic seat→zone→arena_ids map.
- **Spike:** `cargo run --bin card-holder-spike --release` against a live MTGA process during a Brawl match (chosen for the Command-zone coverage). Stdout becomes the FINDING.md.
- **Persistence:** `LiveState.record_final_board/2` test inserts board snapshot + revealed cards in one transaction; failure rolls both back.
- **Server:** test the new tick path with `TestBackend` returning fixture board snapshots; verify `last_board_snapshot` accumulates and is persisted on wind-down.
- **UI:** ADR-013 — extracted helpers (`group_by_zone/1`, etc.) get pure-function tests. No HTML assertions.

## Sub-projects (decomposition for the writing-plans skill)

1. ~~**Walker generic `List<T>`**~~ — **closed by the walker refactor** (`refactor(walker): extract shared primitives per engineering audit`). `mono_array::read_array_elements` already takes element size; `list_t::read_pointer_list` covers `List<TRef>`. Struct-list reads are three lines of caller code — no preemptive helper needed.
2. **Spike capture against live MTGA** — run the existing `match-manager-spike --pid=<MTGA pid>` (its `chain2_deep_dive` already dumps the relevant field manifests), capture stdout, write FINDING.md pinning offsets for `BaseCardHolder._previousLayoutData`, `CardLayoutData`, `BaseCDC._model`, `CardDataAdapter._instance`, `BattlefieldCardHolder.Layout`, `BattlefieldRegion._stacksByShape`, `BattlefieldStack.AllCards`. Gated on the user running MTGA. ~30 min when MTGA is in a Brawl match (chosen for Command-zone coverage).
3. **Walker `card_holder.rs`** — non-battlefield path. ~1 day.
4. **Walker battlefield region traversal** — region/stack drill-down. ~1 day.
5. **MtgaMemory contract + persistence + LiveState.Server integration** — Elixir layer. ~2 days.
6. **UI surface on match detail** — render section + helpers + tests. ~1 day.

Sub-project 2 is the sole remaining blocker. 3 and 4 can be planned in parallel once it lands. 5 depends on 3+4. 6 depends on 5.

## Open questions to resolve during sub-project 2 (spike)

- `_previousLayoutData` field offset on `BaseCardHolder` (current FINDING.md doesn't pin it).
- `CardLayoutData` element size and field offsets (`IsVisibleInLayout`, `Card`).
- `BaseCDC._model` and `CardDataAdapter._instance` offsets.
- `BattlefieldCardHolder.Layout` and downstream offsets.
- `OverlayGrpId.value` handling — alt-art arena_ids replace `BaseGrpId` for display? Or are they additional metadata? (Confirm during spike.)
- Whether `Library` zone's holder is structurally distinguishable from other zones (it should always have face-down entries; confirm walker correctly returns empty `[]`).

The spike's FINDING.md becomes the source-of-truth for these and lands before sub-project 3/4 starts.
