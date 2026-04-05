defmodule Scry2.Drafts.Ingester do
  @moduledoc """
  Consumes raw MTGA log events from PubSub and upserts them into the
  Drafts context.

  ## Wiring

  Subscribes to `Scry2.Topics.mtga_logs_events/0` at startup and receives
  `{:event, id, type}` messages for draft-related events.

  ## Scope

  Draft pick mapping requires real MTGA log fixtures to build correctly
  — pack/pool snapshots and pick sequencing differ between event types.
  This module is currently a **stub** that receives draft events, logs
  their types, and marks them processed without writing to `drafts_*`.
  Domain mapping lands in a follow-up when fixtures are available.

  See ADR-014 (arena_id stable key) and ADR-016 (idempotent ingestion).
  """
  use GenServer

  require Logger

  alias Scry2.MtgaLogs
  alias Scry2.Topics

  @claimed_types ~w(
    DraftMakePick
    DraftPack
    DraftNotify
    EventGetPlayerCourse
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
    Logger.info("drafts ingester received event id=#{id} type=#{type}")

    # TODO: load Scry2.MtgaLogs.EventRecord id=id, dispatch on type,
    # upsert via Scry2.Drafts (upsert_draft!, upsert_pick!), mark_processed!/1.
    MtgaLogs.mark_processed!(id)

    {:noreply, state}
  end

  def handle_info({:event, _id, _type}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}
end
