defmodule Scry2.Drafts.Ingester do
  @moduledoc """
  Consumes raw MTGA log events from PubSub and upserts them into the
  Drafts context.

  ## Wiring

  Subscribes to `Scry2.Topics.mtga_logs_events/0` at startup and receives
  `{:event, id, type}` messages.

  ## Scope

  `@claimed_types` is intentionally empty — the draft-specific event
  names MTGA emits are unknown until a user runs a draft with detailed
  logs enabled and real fixtures can be collected. The original
  speculative list (`DraftMakePick`, `DraftPack`, `DraftNotify`,
  `EventGetPlayerCourse`) did not match observed logs. See
  `TODO.md` → "Match ingestion follow-ups" → Drafts for the plan.

  Structurally this module mirrors `Scry2.Matches.Ingester`: once real
  draft event types are known, add them to `@claimed_types` and extend
  `process_event/2`.

  See ADR-014 (arena_id stable key) and ADR-016 (idempotent ingestion).
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.MtgaLogs
  alias Scry2.Topics

  @claimed_types []

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
    try do
      process_event(id, type)
      MtgaLogs.mark_processed!(id)
    rescue
      error ->
        Log.error(
          :ingester,
          "drafts failed to process id=#{id} type=#{type}: #{inspect(error)}"
        )

        MtgaLogs.mark_error!(id, error)
    end

    {:noreply, state}
  end

  def handle_info({:event, _id, _type}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Placeholder — filled in when draft event fixtures exist.
  defp process_event(id, type) do
    Log.info(:ingester, "drafts received event id=#{id} type=#{type}")
    :ok
  end
end
