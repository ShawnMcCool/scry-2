defmodule Scry2.Matches.Ingester do
  @moduledoc """
  Pipeline stage 07 — consume raw MTGA log events from PubSub and upsert
  them into the Matches context.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:event, id, type}` messages on `Scry2.Topics.mtga_logs_events/0` |
  | **Output** | Rows in `matches_matches` via `Scry2.Matches.upsert_match!/1` + `{:match_updated, id}` broadcast |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.MtgaLogs.insert_event!/1` (stage 05 → 07) |
  | **Calls** | `Scry2.MtgaLogs.get_event!/1` → `Scry2.Matches.EventMapper.*` (stage 08) → `Scry2.Matches.upsert_match!/1` (stage 09) |

  ## Claimed event types

  Only `MatchGameRoomStateChangedEvent` today. The original speculative
  list (`EventMatchCreated`, `MatchStart`, etc.) did not match reality;
  see `TODO.md` > "Match ingestion follow-ups" for everything deferred.

  ## Failure handling

  Dispatch runs inside `try`/`rescue`. On success the event is marked
  processed. On exception the error is recorded via
  `MtgaLogs.mark_error!/2` and the GenServer stays alive — malformed
  payloads should never take down the ingester. Reprocessing is
  supported by clearing the `processed` flag and re-broadcasting.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Config
  alias Scry2.Matches
  alias Scry2.Matches.EventMapper
  alias Scry2.MtgaLogs
  alias Scry2.Topics

  @claimed_types ~w(MatchGameRoomStateChangedEvent)

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
          "matches failed to process id=#{id} type=#{type}: #{inspect(error)}"
        )

        MtgaLogs.mark_error!(id, error)
    end

    {:noreply, state}
  end

  def handle_info({:event, _id, _type}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Load the raw event, dispatch on event type, hand off to EventMapper
  # (stage 08), then to Matches.upsert_match! (stage 09).
  defp process_event(id, "MatchGameRoomStateChangedEvent") do
    record = MtgaLogs.get_event!(id)
    self_user_id = Config.get(:mtga_self_user_id)

    case EventMapper.match_attrs_from_game_room_state_changed(record, self_user_id) do
      {:ok, attrs} ->
        # → stage 09 (Matches.upsert_match!/1)
        match = Matches.upsert_match!(attrs)

        Log.info(
          :ingester,
          "matches upserted mtga_match_id=#{match.mtga_match_id} opponent=#{inspect(attrs.opponent_screen_name)}"
        )

      :ignore ->
        Log.info(
          :ingester,
          "matches skipped id=#{id} type=MatchGameRoomStateChangedEvent (no-op state)"
        )
    end

    :ok
  end
end
