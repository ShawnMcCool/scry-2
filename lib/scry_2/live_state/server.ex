defmodule Scry2.LiveState.Server do
  @moduledoc """
  Live-polling state machine for in-match memory reads (Chain 1).

  ```text
  IDLE
    → MatchCreated domain event (and feature flag enabled)
                         ↓ resolve MTGA pid, schedule first tick
  POLLING
    • every @poll_interval_ms: walk_match_info(pid)
    •   {:ok, snap} → broadcast {:tick, snap} on live_match:updates
    •   {:ok, nil}  → MatchSceneManager.Instance NULL → WINDING_DOWN
    •   {:error, _} → log; continue ticking (transient)
    • on MatchCompleted domain event for this match → WINDING_DOWN
    • on @match_timeout_ms safety timer → WINDING_DOWN
                         ↓
  WINDING_DOWN
    • persist last in-flight snapshot via LiveState.record_final/2
    • broadcast {:final, %Snapshot{}} on live_match:final
    • return to IDLE
  ```

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

  @settings_key "live_match_polling_enabled"

  defmodule State do
    @moduledoc false
    @enforce_keys [:phase, :poll_interval_ms, :match_timeout_ms, :memory]
    defstruct phase: :idle,
              mtga_match_id: nil,
              mtga_pid: nil,
              last_snapshot: nil,
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
        new_state = %{state | last_snapshot: snap, poll_timer: schedule_poll(state)}
        {:noreply, new_state}

      {:error, reason} ->
        Log.warning(
          :ingester,
          "live_state: walk_match_info failed: #{inspect(reason)} (continuing tick)"
        )

        {:noreply, %{state | poll_timer: schedule_poll(state)}}
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

  defp wind_down(state, _reason) do
    cancel_timers(state)

    snapshot_attrs = build_snapshot_attrs(state.last_snapshot)

    case LiveState.record_final(state.mtga_match_id, snapshot_attrs) do
      {:ok, _snapshot} ->
        :ok

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
      poll_interval_ms: state.poll_interval_ms,
      match_timeout_ms: state.match_timeout_ms,
      memory: state.memory,
      poll_timer: nil,
      timeout_timer: nil
    }
  end

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

  defp enabled? do
    case Scry2.Settings.get(@settings_key) do
      nil -> true
      true -> true
      "true" -> true
      false -> false
      "false" -> false
      _ -> true
    end
  end
end
