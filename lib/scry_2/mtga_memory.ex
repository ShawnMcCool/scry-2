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

  v1 only populates entries for the Battlefield zone (`zone_id ==
  4`). Other zones land once the `CardLayoutData` struct shape is
  pinned by a follow-up live spike.
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
