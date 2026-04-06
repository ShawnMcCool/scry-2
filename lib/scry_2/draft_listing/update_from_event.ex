defmodule Scry2.DraftListing.UpdateFromEvent do
  @moduledoc """
  Pipeline stage 09 — project draft-related domain events into the
  `drafts_*` read models.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:domain_event, id, type_slug}` messages on `domain:events` |
  | **Output** | Rows in `drafts_drafts` / `drafts_picks` via `Scry2.DraftListing.upsert_*!/1` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.Events.append!/2` |
  | **Calls** | `Scry2.Events.get!/1` → `Scry2.DraftListing.upsert_draft!/1` / `upsert_pick!/1` |

  ## Status

  `@claimed_slugs` is empty — the translator does not yet produce any
  draft domain events because the user's Player.log contains no draft
  activity. This module exists as a structural placeholder matching
  `Scry2.MatchListing.UpdateFromEvent`, so that once draft fixtures exist and the
  translator learns `%DraftStarted{}` / `%DraftPickMade{}`, the projector
  pattern is already in place.

  See `TODO.md` > "Match ingestion follow-ups" > Drafts.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Events
  alias Scry2.Events.{DraftPickMade, DraftStarted}
  alias Scry2.Topics

  @claimed_slugs []

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.domain_events())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:domain_event, id, type_slug}, state) when type_slug in @claimed_slugs do
    try do
      event = Events.get!(id)
      project(event)
    rescue
      error ->
        Log.error(
          :ingester,
          "drafts projector failed on domain_event id=#{id} type=#{type_slug}: #{inspect(error)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:domain_event, _id, _type_slug}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Placeholder handlers. Once the translator produces these events and
  # the @claimed_slugs list is populated, these clauses will be reached.
  defp project(%DraftStarted{}), do: :ok
  defp project(%DraftPickMade{}), do: :ok
end
