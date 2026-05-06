defmodule Scry2.MtgaMemory do
  @moduledoc """
  Behaviour for the MTGA process-memory primitives the rest of the app
  uses to read live state out of the running MTGA client.

  Memory access is a parent-level capability: multiple consumers
  (`Scry2.Collection.Reader` for the inventory walk,
  `Scry2.LiveState` for in-match polling) bind to this behaviour
  unidirectionally — they don't talk to each other, they all talk to
  this contract.

  Two implementations:

    * `Scry2.MtgaMemory.Nif` — production; dispatches into the
      `scry2_collection_reader` Rust crate.
    * `Scry2.MtgaMemory.TestBackend` — in-memory fixture; used in
      unit tests so callers can be exercised with synthetic layouts.

  Configured via

      config :scry_2, Scry2.MtgaMemory, impl: <module>

  and resolved at call-time through `impl/0`.
  """

  @typedoc "A process identifier as seen by the host OS (pid_t / DWORD)."
  @type pid_int :: non_neg_integer()

  @typedoc """
  One mapped memory region in the target process.

  Mirrors the useful columns of `/proc/<pid>/maps` on Linux and the
  output of `VirtualQueryEx` on Windows.
  """
  @type map_entry :: %{
          required(:start) => non_neg_integer(),
          required(:end_addr) => non_neg_integer(),
          required(:perms) => String.t(),
          required(:path) => String.t() | nil
        }

  @typedoc """
  Enough to identify a live process for MTGA discovery purposes.

  `:name` is the short executable name (e.g. `"MTGA"`); `:cmdline` is
  the full command line, whitespace-normalised.
  """
  @type process_info :: %{
          required(:pid) => pid_int(),
          required(:name) => String.t(),
          required(:cmdline) => String.t()
        }

  @doc "Read `size` bytes at virtual address `addr` in process `pid`."
  @callback read_bytes(pid_int(), non_neg_integer(), non_neg_integer()) ::
              {:ok, binary()} | {:error, atom()}

  @doc "Enumerate mapped memory regions of process `pid`."
  @callback list_maps(pid_int()) :: {:ok, [map_entry()]} | {:error, atom()}

  @doc """
  Return the pid of the first process for which `predicate` returns true.
  """
  @callback find_process((process_info() -> boolean())) ::
              {:ok, pid_int()} | {:error, atom()}

  @typedoc """
  Walker snapshot returned by `walk_collection/1` — the data the
  Rust walker harvests in one pass through MTGA's Mono runtime.
  Matches the contract in ADR 034 Revision 2026-04-25.
  """
  @type walker_snapshot :: %{
          required(:cards) => [{integer(), integer()}],
          required(:wildcards) => %{
            required(:common) => integer(),
            required(:uncommon) => integer(),
            required(:rare) => integer(),
            required(:mythic) => integer()
          },
          required(:gold) => integer(),
          required(:gems) => integer(),
          required(:vault_progress) => float(),
          required(:build_hint) => String.t() | nil,
          required(:reader_version) => String.t()
        }

  @doc """
  Walk MTGA's process memory and return the parsed collection +
  inventory in one shot.

  Implementations should propagate any walker-internal failure as
  `{:error, atom() | tuple()}`. The Reader uses any error as a
  signal to fall back to the structural-scan path.
  """
  @callback walk_collection(pid_int()) :: {:ok, walker_snapshot()} | {:error, term()}

  @typedoc """
  PlayerInfo block returned by `walk_match_info/1` — same shape for
  both local and opponent. All fields default to zero / `nil` when
  the underlying object exists but the field couldn't be resolved.
  """
  @type player_info :: %{
          required(:screen_name) => String.t() | nil,
          required(:seat_id) => integer(),
          required(:team_id) => integer(),
          required(:ranking_class) => integer(),
          required(:ranking_tier) => integer(),
          required(:mythic_percentile) => integer(),
          required(:mythic_placement) => integer(),
          required(:commander_grp_ids) => [integer()]
        }

  @typedoc """
  MatchManager snapshot returned by `walk_match_info/1`. Surfaces the
  Chain-1 fields documented in
  `decisions/research/2026-04-30-001-opponent-game-state-memory-read.md`.

  Returned as `nil` (i.e. `{:ok, nil}`) when MTGA is running but
  `PAPA._instance.MatchManager` is null — i.e. no active match.
  """
  @type match_info :: %{
          required(:local) => player_info(),
          required(:opponent) => player_info(),
          required(:match_id) => String.t() | nil,
          required(:format) => integer(),
          required(:variant) => integer(),
          required(:session_type) => integer(),
          required(:current_game_number) => integer(),
          required(:match_state) => integer(),
          required(:local_player_seat_id) => integer(),
          required(:is_practice_game) => boolean(),
          required(:is_private_game) => boolean(),
          required(:reader_version) => String.t()
        }

  @doc """
  Read one MatchManager snapshot (rank, screen name, commander grpIds)
  from the target MTGA process via the Chain-1 walker.

  Returns:
    * `{:ok, %{...}}` when a match is active.
    * `{:ok, nil}` when MTGA is running but no match is in flight
      (PAPA._instance.MatchManager is null) — this is normal, not
      an error.
    * `{:error, reason}` for upstream walker failures (mono DLL
      missing, PAPA class not found, etc.).

  `Scry2.LiveState` calls this every 500 ms while a match is active.
  """
  @callback walk_match_info(pid_int()) :: {:ok, match_info() | nil} | {:error, term()}

  @typedoc """
  One (seat, zone) entry in [`board_snapshot/0`]. `seat_id` and
  `zone_id` are MTGA's own enum integers — symbolic translation is
  the caller's job (see `Scry2.LiveState.SeatId` / `Scry2.LiveState.ZoneId`).
  """
  @type seat_zone_cards :: %{
          required(:seat_id) => integer(),
          required(:zone_id) => integer(),
          required(:arena_ids) => [integer()]
        }

  @typedoc """
  Board-state snapshot returned by `walk_match_board/1`. Surfaces
  the cards visible in each (seat, zone) at the moment of the read.

  Returned as `nil` (`{:ok, nil}`) when MTGA is running but
  `MatchSceneManager.Instance` is null — i.e. no active match scene
  (the duel UI hasn't loaded, or it's torn down). This is the
  authoritative signal for `Scry2.LiveState.Server` to wind down.
  """
  @type board_snapshot :: %{
          required(:zones) => [seat_zone_cards()],
          required(:reader_version) => String.t()
        }

  @doc """
  Read one board-state snapshot (per-zone arena_ids per seat) from
  the target MTGA process via the Chain-2 walker.

  Returns:
    * `{:ok, %{...}}` when a match scene is active.
    * `{:ok, nil}` when no active match scene — normal, not an error.
    * `{:error, reason}` for upstream walker failures.

  `Scry2.LiveState.Server` calls this on the same poll cadence as
  `walk_match_info/1`; the last successful read is persisted at
  wind-down.
  """
  @callback walk_match_board(pid_int()) :: {:ok, board_snapshot() | nil} | {:error, term()}

  @typedoc """
  Battle-pass / mastery-pass snapshot returned by `walk_mastery/1`.
  Surfaces the player's current pass tier, XP toward the next tier,
  mastery orb count, and the live season identifier + expiration.

  Returned as `nil` (i.e. `{:ok, nil}`) when MTGA is running but the
  mastery anchor isn't reachable — between seasons, or the runtime
  `_strategy` class doesn't match the production `AwsSetMasteryStrategy`
  (walker fails safe rather than read at the wrong offsets).

  `expiration_time_ticks` is the raw .NET `DateTime.Ticks` value
  (100-ns since 0001-01-01 UTC); consumers convert at the boundary
  (see `Scry2.Collection.Reader`).
  """
  @type mastery_info :: %{
          required(:tier) => integer(),
          required(:xp_in_tier) => integer(),
          required(:orbs) => integer(),
          required(:season_name) => String.t() | nil,
          required(:expiration_time_ticks) => integer() | nil
        }

  @doc """
  Read one battle-pass / mastery snapshot (current tier, XP toward next
  tier, orbs, season name, expiration ticks) from the target MTGA
  process via the 3-hop chain `PAPA._instance →
  SetMasteryDataProvider._strategy → AwsSetMasteryStrategy._currentBpTrack
  → ProgressionTrack`.

  Returns:
    * `{:ok, %{...}}` when the chain resolves end-to-end.
    * `{:ok, nil}` when MTGA is running but the chain isn't reachable
      (between seasons / strategy is non-production / current track
      null) — this is normal, not an error.
    * `{:error, reason}` for upstream walker failures (mono DLL missing,
      PAPA class not found, etc.).

  Called once per `Scry2.Collection.Reader` snapshot — same cadence as
  `walk_collection/1`. The walker shares the per-pid discovery cache
  shipped in v0.31.0 so the second walk per snapshot pays no
  discovery cost.
  """
  @callback walk_mastery(pid_int()) :: {:ok, mastery_info() | nil} | {:error, term()}

  @typedoc """
  One row in `event_list().records` — a projection of a single MTGA
  `EventContext`. See `Scry2.MtgaMemory.walk_events/1`.

  Field meanings:

  * `internal_event_name` — stable identifier (e.g. `"Premier_Draft_DFT"`).
    Distinct from the user-facing localised name; consumers that want
    the player-visible label resolve it via MTGA's loc tables.
  * `current_event_state` — `0` = available, `1` = entered/in-progress,
    `3` = standing/always-on (Play, Ladder).
  * `current_module` — round/module pointer; `0/1/7/11` observed.
  * `event_state` — event-template lifecycle: `0` = open, `1` = closed,
    `2` = special.
  * `format_type` — `1` = Limited, `2` = Sealed, `3` = Constructed.
  * `current_wins` / `current_losses` — match counters from
    `ClientPlayerCourseV3`.
  * `format_name` — `"Standard"` / `"Alchemy"` / etc; `nil` on Limited
    events (Limited derives format from the draft pool).
  """
  @type event_record :: %{
          required(:internal_event_name) => String.t() | nil,
          required(:current_event_state) => integer(),
          required(:current_module) => integer(),
          required(:event_state) => integer(),
          required(:format_type) => integer(),
          required(:current_wins) => integer(),
          required(:current_losses) => integer(),
          required(:format_name) => String.t() | nil
        }

  @typedoc "Active-events snapshot returned by `walk_events/1`."
  @type event_list :: %{
          required(:records) => [event_record()],
          required(:reader_version) => String.t()
        }

  @doc """
  Read the player's full active-events list (Chain 3) from the target
  MTGA process via `PAPA._instance.<EventManager>k__BackingField →
  EventContexts → [BasicPlayerEvent → EventInfoV3 + CourseData +
  AwsCourseInfo._clientPlayerCourse → ClientPlayerCourseV3]`.

  Returns:
    * `{:ok, %{records: [...], reader_version: "..."}}` when the chain
      resolves. The records list may be empty if MTGA holds no event
      contexts (rare — the global filter list alone usually populates
      it within seconds of login).
    * `{:ok, nil}` when MTGA is running but the EventManager anchor is
      null — pre-login or freshly torn-down session. Normal, not an
      error.
    * `{:error, reason}` for upstream walker failures (mono DLL
      missing, PAPA class not found, etc.).

  Unlike Chain 1 (`walk_match_info`) and Chain 2 (`walk_match_board`),
  this chain is stable across match boundaries — it does NOT need to
  be polled within an active match. A periodic refresh on the
  collection-reader cadence is sufficient.
  """
  @callback walk_events(pid_int()) :: {:ok, event_list() | nil} | {:error, term()}

  @doc """
  Returns the configured backend module.

  Set via `config :scry_2, Scry2.MtgaMemory, impl: <module>`.
  Defaults to `Scry2.MtgaMemory.Nif` in dev/prod and
  `Scry2.MtgaMemory.TestBackend` in test.
  """
  @spec impl() :: module()
  def impl do
    :scry_2
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(:impl)
  end
end
