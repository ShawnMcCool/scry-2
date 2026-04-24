defmodule Scry2.Collection.ActivityTrigger do
  @moduledoc """
  Auto-triggers a collection refresh when MTGA log activity resumes.

  Subscribes to `domain:events`. Any domain event implies MTGA wrote to
  `Player.log` and the parser/translator produced output — i.e. the game
  is running right now. On the first event after a cooldown window,
  enqueues a `Scry2.Collection.RefreshJob` with `trigger: "log_activity"`.
  The RefreshJob itself calls `find_mtga/1` and discards cleanly if the
  process has already exited, so no extra process check is needed here.

  The in-process cooldown avoids enqueueing a job for every event during
  active play. It's independent of — and stricter than — Oban's own
  `unique` window on `RefreshJob`, which protects against races.

  Lives under the ingestion branch of the supervision tree (only started
  when `start_watcher` is true) so it never runs in tests or in envs
  where the MTGA pipeline is disabled.
  """

  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Collection
  alias Scry2.Topics

  @cooldown :timer.minutes(5)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.domain_events())
    {:ok, %{last_triggered_at: 0}}
  end

  @impl true
  def handle_info({:domain_event, _id, _type}, state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_triggered_at >= @cooldown do
      case Collection.refresh(trigger: "log_activity") do
        {:ok, _job} ->
          Log.info(:system, "collection refresh enqueued from log activity")

        {:error, reason} ->
          Log.warning(:system, fn ->
            "collection auto-refresh enqueue failed: #{inspect(reason)}"
          end)
      end

      {:noreply, %{state | last_triggered_at: now}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}
end
