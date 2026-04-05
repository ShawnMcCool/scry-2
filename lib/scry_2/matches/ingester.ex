defmodule Scry2.Matches.Ingester do
  @moduledoc """
  Consumes raw MTGA log events from PubSub and upserts them into the
  Matches context.

  ## Wiring

  Subscribes to `Scry2.Topics.mtga_logs_events/0` at startup and receives
  `{:event, id, type}` messages. Looks up the raw event by id, dispatches
  on `type`, and marks the event processed on success.

  ## Scope

  Match/game/deck mapping requires real MTGA log fixtures to build
  correctly — event payload shapes drift between MTGA releases and
  guessing the mapping leads to bugs that corrupt historical data
  (see ADR-015). This module is currently a **stub**: it receives
  events, logs their types, and marks them processed without writing
  to `matches_*`. Domain mapping lands in a follow-up when fixtures
  are available under `test/fixtures/mtga_logs/`.

  Idempotency will be enforced via MTGA-provided ids when the real
  mapping is added (ADR-016).
  """
  use GenServer

  require Logger

  alias Scry2.MtgaLogs
  alias Scry2.Topics

  # Events this ingester claims. Any other event_type is ignored so the
  # drafts ingester can handle drafts independently.
  @claimed_types ~w(
    EventMatchCreated
    MatchStart
    MatchEnd
    MatchCompleted
    GameComplete
    EventDeckSubmit
    EventJoin
    EventPayEntry
  )

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.mtga_logs_events())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, id, type}, state) when type in @claimed_types do
    Logger.info("matches ingester received event id=#{id} type=#{type}")

    # TODO: load Scry2.MtgaLogs.EventRecord id=id, dispatch on type,
    # upsert via Scry2.Matches, mark_processed!/1. Requires real
    # fixtures for the event payload shape — see ADR-015.
    MtgaLogs.mark_processed!(id)

    {:noreply, state}
  end

  def handle_info({:event, _id, _type}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}
end
