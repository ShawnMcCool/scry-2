defmodule Scry2.LiveState.Server do
  @moduledoc """
  Live-polling state machine for in-match memory reads (Chain 1
  rank/screen-name + Chain 2 board state).

  ```text
  IDLE
    → MatchCreated domain event (and feature flag enabled)
                         ↓ resolve MTGA pid, schedule first tick
  POLLING
    • every @poll_interval_ms:
        - walk_match_info(pid)              [Chain 1, authoritative]
        - walk_match_board(pid)             [Chain 2, best-effort]
    •   {:ok, snap} → broadcast {:tick, snap} on live_match:updates
    •   {:ok, nil}  → MatchSceneManager.Instance NULL → WINDING_DOWN
    •   {:error, _} → MTGA gone or memory layout broken → WINDING_DOWN
    • on MatchCompleted domain event for this match → WINDING_DOWN
    • on @match_timeout_ms safety timer → WINDING_DOWN
                         ↓
  WINDING_DOWN
    • persist last in-flight snapshot via LiveState.record_final/2
    • if any board snapshot was captured: persist via
      LiveState.record_final_board/2 (broadcasts on live_match:board_final)
    • broadcast {:final, %Snapshot{}} on live_match:final
    • return to IDLE
  ```

  Chain-2 reads are best-effort: errors / `nil` results from
  `walk_match_board` are logged at INFO level and the previous good
  snapshot is kept. Only `walk_match_info` failures wind down the
  polling loop.

  Wind-down on `{:error, _}` is structural, not a transient retry.
  When MTGA quits mid-match the cached `mtga_pid` is invalid: best
  case the NIF returns `{:error, _}` quickly and we'd otherwise log-
  and-tick forever; worst case a re-used pid leads the walker into
  a non-terminating pointer chase on garbage memory and pegs a
  dirty-IO scheduler at 100% CPU. Either way, the right move is to
  stop polling — the next match's `MatchCreated` event will
  re-resolve the pid from a fresh process listing.

  See `decisions/research/2026-04-30-001-opponent-game-state-memory-read.md`.

  ## Settings

  The state machine consults `Scry2.Settings.get_boolean(:live_match_polling_enabled)`
  at each `MatchCreated` event. When false, the event is ignored and the
  process stays IDLE. The flag is intentionally checked at boundary
  events (not on every tick) to avoid mid-match toggles tearing down a
  capture in flight.
  """

  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.LiveState
  alias Scry2.MtgaMemory
  alias Scry2.Topics

  @default_poll_interval_ms 500
  @default_match_timeout_ms 90 * 60 * 1000

  defmodule State do
    @moduledoc false
    @enforce_keys [:phase, :poll_interval_ms, :match_timeout_ms, :memory]
    defstruct phase: :idle,
              mtga_match_id: nil,
              mtga_pid: nil,
              last_snapshot: nil,
              last_board_snapshot: nil,
              poll_interval_ms: nil,
              match_timeout_ms: nil,
              memory: nil,
              poll_timer: nil,
              timeout_timer: nil
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Topics.subscribe(Topics.domain_events())

    # Test hook: tests inject TestBackend fixtures into this process's
    # dictionary (TestBackend's storage) without using :sys helpers.
    if init_fn = Keyword.get(opts, :on_init), do: init_fn.()

    state = %State{
      phase: :idle,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      match_timeout_ms: Keyword.get(opts, :match_timeout_ms, @default_match_timeout_ms),
      memory: Keyword.get(opts, :memory) || MtgaMemory.impl()
    }

    {:ok, state}
  end

  # ── domain event handlers ─────────────────────────────────────────────

  @impl true
  def handle_info({:domain_event, _id, "match_created", %MatchCreated{} = event}, state) do
    cond do
      not enabled?() ->
        {:noreply, state}

      state.phase != :idle ->
        Log.warning(
          :ingester,
          "live_state: MatchCreated received in phase=#{state.phase}; ignoring"
        )

        {:noreply, state}

      true ->
        case resolve_mtga_pid(state.memory) do
          {:ok, pid} ->
            new_state = enter_polling(state, event.mtga_match_id, pid)
            {:noreply, new_state}

          {:error, reason} ->
            Log.warning(
              :ingester,
              "live_state: cannot start polling — #{inspect(reason)} (MTGA not running?)"
            )

            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:domain_event, _id, "match_completed", %MatchCompleted{} = event}, state) do
    if state.phase == :polling and state.mtga_match_id == event.mtga_match_id do
      {:noreply, wind_down(state, :match_completed)}
    else
      {:noreply, state}
    end
  end

  # Other domain events — ignore.
  @impl true
  def handle_info({:domain_event, _id, _slug, _event}, state), do: {:noreply, state}

  @impl true
  def handle_info({:domain_event, _id, _slug}, state), do: {:noreply, state}

  # ── timers ────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:poll_tick, %State{phase: :polling} = state) do
    case state.memory.walk_match_info(state.mtga_pid) do
      {:ok, nil} ->
        # MatchSceneManager.Instance went null — match scene torn down.
        {:noreply, wind_down(state, :scene_torn_down)}

      {:ok, snap} when is_map(snap) ->
        LiveState.broadcast_tick(snap)
        board = read_board_safely(state)

        new_state = %{
          state
          | last_snapshot: snap,
            last_board_snapshot: board || state.last_board_snapshot,
            poll_timer: schedule_poll(state)
        }

        {:noreply, new_state}

      {:error, reason} ->
        # MTGA gone or memory layout broken — wind down rather than
        # re-polling indefinitely. See @moduledoc for rationale.
        Log.warning(
          :ingester,
          "live_state: walk_match_info failed: #{inspect(reason)}; winding down"
        )

        {:noreply, wind_down(state, {:walk_error, reason})}
    end
  end

  # Late tick after a phase change — drop it.
  @impl true
  def handle_info(:poll_tick, state), do: {:noreply, state}

  @impl true
  def handle_info(:match_timeout, %State{phase: :polling} = state) do
    Log.warning(
      :ingester,
      "live_state: match_timeout reached for #{state.mtga_match_id}; winding down"
    )

    {:noreply, wind_down(state, :timeout)}
  end

  @impl true
  def handle_info(:match_timeout, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── transitions ───────────────────────────────────────────────────────

  defp enter_polling(state, match_id, pid) do
    cancel_timers(state)

    %{
      state
      | phase: :polling,
        mtga_match_id: match_id,
        mtga_pid: pid,
        last_snapshot: nil,
        poll_timer: schedule_poll(state),
        timeout_timer: Process.send_after(self(), :match_timeout, state.match_timeout_ms)
    }
  end

  # Chain-2 read tolerated as best-effort — Chain-1 owns the
  # wind-down decision. Returns nil on any error or scene-torn-down;
  # the caller falls back to the previous successful read.
  defp read_board_safely(state) do
    case state.memory.walk_match_board(state.mtga_pid) do
      {:ok, snap} when is_map(snap) ->
        snap

      {:ok, nil} ->
        nil

      {:error, reason} ->
        Log.info(:ingester, fn ->
          "live_state: walk_match_board returned error #{inspect(reason)}; keeping last good"
        end)

        nil
    end
  end

  defp wind_down(state, _reason) do
    cancel_timers(state)

    snapshot_attrs = build_snapshot_attrs(state.last_snapshot)

    Log.warning(:ingester, fn ->
      "live_state: chain-2 wind-down — #{chain_2_summary(state.last_board_snapshot)}"
    end)

    case LiveState.record_final(state.mtga_match_id, snapshot_attrs) do
      {:ok, _snapshot} ->
        # Chain-1 persistence succeeded — try Chain-2 too, but only
        # if we actually captured a board snapshot at some point. The
        # board persistence depends on the parent snapshot existing,
        # which it now does.
        if state.last_board_snapshot do
          case LiveState.record_final_board(state.mtga_match_id, state.last_board_snapshot) do
            {:ok, _board} ->
              :ok

            {:error, reason} ->
              Log.error(
                :ingester,
                "live_state: failed to persist final board snapshot: #{inspect(reason)}"
              )
          end
        end

      {:error, changeset} ->
        Log.error(
          :ingester,
          "live_state: failed to persist final snapshot: #{inspect(changeset)}"
        )
    end

    %State{
      phase: :idle,
      mtga_match_id: nil,
      mtga_pid: nil,
      last_snapshot: nil,
      last_board_snapshot: nil,
      poll_interval_ms: state.poll_interval_ms,
      match_timeout_ms: state.match_timeout_ms,
      memory: state.memory,
      poll_timer: nil,
      timeout_timer: nil
    }
  end

  # Summarises the captured Chain-2 board snapshot for the wind-down
  # diagnostic. Three outcomes the prod log can distinguish:
  #
  #   - "no snapshot captured during match" — every walk_match_board
  #     tick returned nil/error, so MatchSceneManager.Instance was
  #     unreachable for the whole match (or the chain failed before
  #     producing any holders to walk).
  #   - "snapshot present, zones=N, cards=M" with N>0 — the chain
  #     produced cards (working or partially working).
  #   - "snapshot present but empty" — the chain reached the
  #     PlayerTypeMap but every per-zone walk returned empty/None.
  defp chain_2_summary(nil), do: "no snapshot captured during match"

  defp chain_2_summary(%{zones: zones}) when is_list(zones) do
    if zones == [] do
      "snapshot present but empty"
    else
      card_count = Enum.reduce(zones, 0, fn z, acc -> acc + length(z.arena_ids) end)
      "snapshot present, zones=#{length(zones)}, cards=#{card_count}"
    end
  end

  defp chain_2_summary(_other), do: "snapshot present but unrecognized shape"

  defp build_snapshot_attrs(nil) do
    # No tick ever succeeded — persist a minimal row with reader_version
    # so downstream code can tell "we tried but got nothing."
    %{reader_version: "unknown"}
  end

  defp build_snapshot_attrs(snap) when is_map(snap) do
    local = Map.get(snap, :local, %{})
    opponent = Map.get(snap, :opponent, %{})

    %{
      local_screen_name: Map.get(local, :screen_name),
      local_seat_id: Map.get(local, :seat_id),
      local_team_id: Map.get(local, :team_id),
      local_ranking_class: Map.get(local, :ranking_class),
      local_ranking_tier: Map.get(local, :ranking_tier),
      local_mythic_percentile: Map.get(local, :mythic_percentile),
      local_mythic_placement: Map.get(local, :mythic_placement),
      local_commander_grp_ids: Map.get(local, :commander_grp_ids, []),
      opponent_screen_name: Map.get(opponent, :screen_name),
      opponent_seat_id: Map.get(opponent, :seat_id),
      opponent_team_id: Map.get(opponent, :team_id),
      opponent_ranking_class: Map.get(opponent, :ranking_class),
      opponent_ranking_tier: Map.get(opponent, :ranking_tier),
      opponent_mythic_percentile: Map.get(opponent, :mythic_percentile),
      opponent_mythic_placement: Map.get(opponent, :mythic_placement),
      opponent_commander_grp_ids: Map.get(opponent, :commander_grp_ids, []),
      format: Map.get(snap, :format),
      variant: Map.get(snap, :variant),
      session_type: Map.get(snap, :session_type),
      is_practice_game: Map.get(snap, :is_practice_game, false),
      is_private_game: Map.get(snap, :is_private_game, false),
      reader_version: Map.get(snap, :reader_version, "unknown")
    }
  end

  defp schedule_poll(state) do
    Process.send_after(self(), :poll_tick, state.poll_interval_ms)
  end

  defp cancel_timers(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    if state.timeout_timer, do: Process.cancel_timer(state.timeout_timer)
    :ok
  end

  defp resolve_mtga_pid(memory) do
    memory.find_process(fn %{name: name} ->
      String.starts_with?(name, "MTGA")
    end)
  end

  defp enabled?, do: LiveState.enabled?()
end
