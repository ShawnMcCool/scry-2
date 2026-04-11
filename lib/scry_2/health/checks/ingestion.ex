defmodule Scry2.Health.Checks.Ingestion do
  @moduledoc """
  Pure ingestion-category checks. Answers:

    1. Can we locate `Player.log`?
    2. Is the watcher running?
    3. Has MTGA actually written structured events (Detailed Logs on)?

  Each function takes its data as arguments and returns a `%Check{}`.
  No context calls, no GenServer calls — the facade does that and
  passes the pre-collected inputs in.
  """

  alias Scry2.Health.Check

  @doc """
  Reports whether `Scry2.MtgaLogIngestion.LocateLogFile.resolve/0` found
  a `Player.log` file. Pass the raw result directly.

  Failure mode: `{:error, :not_found}` — requires human input. MTGA may
  not be installed, or Detailed Logs hasn't been enabled yet (which
  causes MTGA to not create `Player.log` in some configurations).
  """
  @spec player_log_locatable({:ok, String.t()} | {:error, :not_found}) :: Check.t()
  def player_log_locatable({:ok, path}) do
    Check.new(
      id: :player_log_locatable,
      category: :ingestion,
      name: "Player.log locatable",
      status: :ok,
      summary: "Found at #{path}"
    )
  end

  def player_log_locatable({:error, :not_found}) do
    Check.new(
      id: :player_log_locatable,
      category: :ingestion,
      name: "Player.log locatable",
      status: :error,
      summary: "Player.log not found in any known location",
      detail:
        "MTGA may not be installed, or Detailed Logs (Plugin Support) hasn't been enabled yet. " <>
          "Enable it in MTGA Options → View Account, or set the path manually.",
      fix: :manual
    )
  end

  @doc """
  Reports whether the watcher GenServer is running and actively tailing
  Player.log. Pass the full `Watcher.status/0` result map.

  Failure modes:
    * `:not_running` — the GenServer has crashed or isn't started
    * `:path_not_found` — never found a file to tail (fix: reload)
    * `:path_missing` — previously tailed file was deleted/renamed
    * `:starting` — still bootstrapping (pending, not a failure)
  """
  @spec watcher_running(map()) :: Check.t()
  def watcher_running(%{state: :running} = status) do
    Check.new(
      id: :watcher_running,
      category: :ingestion,
      name: "Watcher running",
      status: :ok,
      summary: "Tailing #{status.path} at offset #{status.offset}"
    )
  end

  def watcher_running(%{state: :starting}) do
    Check.new(
      id: :watcher_running,
      category: :ingestion,
      name: "Watcher running",
      status: :pending,
      summary: "Watcher is still starting up"
    )
  end

  def watcher_running(%{state: :path_not_found}) do
    Check.new(
      id: :watcher_running,
      category: :ingestion,
      name: "Watcher running",
      status: :error,
      summary: "Watcher is idle — no Player.log to tail",
      detail: "The watcher will pick up automatically once Player.log becomes available.",
      fix: :reload_watcher
    )
  end

  def watcher_running(%{state: :path_missing}) do
    Check.new(
      id: :watcher_running,
      category: :ingestion,
      name: "Watcher running",
      status: :error,
      summary: "Previously tailed log file was deleted or renamed",
      fix: :reload_watcher
    )
  end

  def watcher_running(%{state: :not_running}) do
    Check.new(
      id: :watcher_running,
      category: :ingestion,
      name: "Watcher running",
      status: :error,
      summary: "Watcher process is not running",
      detail:
        "The watcher GenServer is not alive. Check logs for a crash, or verify " <>
          "start_watcher is true in your config.",
      fix: :reload_watcher
    )
  end

  def watcher_running(%{state: state}) do
    Check.new(
      id: :watcher_running,
      category: :ingestion,
      name: "Watcher running",
      status: :warning,
      summary: "Unknown watcher state: #{inspect(state)}"
    )
  end

  @doc """
  Detects whether MTGA's "Detailed Logs (Plugin Support)" setting is on.

  Structured events are what distinguishes a useful `Player.log` from
  one where MTGA only writes plain-text diagnostics. We infer the
  setting from the raw event counts: if there are any raw events at
  all, at least some of them should be recognized types — otherwise
  the log is just noise and Detailed Logs is almost certainly off.

  Inputs:
    * `total_raw` — count of raw events persisted (`MtgaLogIngestion.count_all/0`)
    * `events_by_type` — map of type => count (`MtgaLogIngestion.count_by_type/0`)
    * `known_types` — `MapSet` from `IdentifyDomainEvents.known_event_types/0`

  States:
    * `:pending` — zero raw events so far; we can't tell yet
    * `:error` — at least `@min_raw_threshold` raw events but zero are recognized
    * `:warning` — some recognized events but most are unknown
    * `:ok` — recognized events are present
  """
  @min_raw_threshold 5

  @spec structured_events_seen(non_neg_integer(), %{String.t() => non_neg_integer()}, MapSet.t()) ::
          Check.t()
  def structured_events_seen(0, _events_by_type, _known_types) do
    Check.new(
      id: :structured_events_seen,
      category: :ingestion,
      name: "Detailed Logs enabled",
      status: :pending,
      summary: "Waiting for the first log event",
      detail:
        "Launch MTGA and open any screen. Once events start flowing, this check " <>
          "will turn green. If it turns red instead, you need to enable " <>
          "Options → View Account → Detailed Logs (Plugin Support) inside MTGA."
    )
  end

  def structured_events_seen(total_raw, events_by_type, known_types)
      when is_integer(total_raw) and is_map(events_by_type) do
    recognized_count =
      events_by_type
      |> Enum.filter(fn {type, _count} -> MapSet.member?(known_types, type) end)
      |> Enum.map(fn {_type, count} -> count end)
      |> Enum.sum()

    cond do
      recognized_count == 0 and total_raw >= @min_raw_threshold ->
        Check.new(
          id: :structured_events_seen,
          category: :ingestion,
          name: "Detailed Logs enabled",
          status: :error,
          summary: "No structured events after #{total_raw} raw lines",
          detail:
            "MTGA is writing to Player.log but nothing in it looks like a structured " <>
              "event. This almost always means Detailed Logs (Plugin Support) is OFF. " <>
              "Enable it in MTGA Options → View Account → Detailed Logs.",
          fix: :manual
        )

      recognized_count == 0 ->
        Check.new(
          id: :structured_events_seen,
          category: :ingestion,
          name: "Detailed Logs enabled",
          status: :pending,
          summary: "Only #{total_raw} raw lines so far, no structured events yet",
          detail: "If nothing appears after launching MTGA, enable Detailed Logs."
        )

      recognized_count < total_raw / 2 ->
        Check.new(
          id: :structured_events_seen,
          category: :ingestion,
          name: "Detailed Logs enabled",
          status: :warning,
          summary: "Most log lines are not recognized event types",
          detail:
            "#{recognized_count} of #{total_raw} lines are known event types. This is " <>
              "unusual — either the log format changed, or an event type is new."
        )

      true ->
        Check.new(
          id: :structured_events_seen,
          category: :ingestion,
          name: "Detailed Logs enabled",
          status: :ok,
          summary: "#{recognized_count} structured events seen"
        )
    end
  end
end
