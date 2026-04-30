defmodule Scry2.MatchEconomy.Trigger do
  @moduledoc """
  Subscribes to `domain:events`. On `MatchCreated` and `MatchCompleted`
  spawns a `Task.Supervisor` task that synchronously reads the MTGA
  collection from memory, persists a tagged `Collection.Snapshot`, and
  upserts a `MatchEconomy.Summary` row with computed deltas + log
  reconciliation.

  See ADR-036 §2.

  Handler implementations land in Bundle 2 (Tasks 4.4-4.6).
  """

  use GenServer

  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.MatchEconomy
  alias Scry2.MatchEconomy.Capture
  alias Scry2.Topics

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Topics.subscribe(Topics.domain_events())
    state = %{task_sup: Keyword.get(opts, :task_sup, Scry2.MatchEconomy.TaskSupervisor)}
    {:ok, state}
  end

  @impl true
  def handle_info({:domain_event, _id, %MatchCreated{} = event}, state) do
    if MatchEconomy.capture_enabled?() do
      Task.Supervisor.start_child(state.task_sup, fn ->
        Capture.handle_match_created(event)
      end)
    end

    {:noreply, state}
  end

  def handle_info({:domain_event, _id, %MatchCompleted{} = event}, state) do
    if MatchEconomy.capture_enabled?() do
      Task.Supervisor.start_child(state.task_sup, fn ->
        Capture.handle_match_completed(event)
      end)
    end

    {:noreply, state}
  end

  def handle_info({:domain_event, _id, _other}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}
end
