defmodule Scry2.Events.IngestRawEvents do
  @moduledoc """
  Pipeline stage 08 — consume raw MTGA events from PubSub, translate to
  domain events, persist to the event log, broadcast to projectors.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:event, %EventRecord{}}` messages on `mtga_logs:events` |
  | **Output** | Persisted rows in `domain_events` + broadcasts on `domain:events` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.MtgaLogIngestion.insert_event!/1` (stage 05 → 08) |
  | **Calls** | `IdentifyDomainEvents.translate/2` (stage 07) → `Events.append!/2` |

  ## Responsibilities

  This is the ONLY subscriber of `mtga_logs:events` in the system.
  Every downstream concern (matches, drafts, analytics, overlays)
  subscribes to `domain:events` instead — the anti-corruption layer
  is enforced at the PubSub boundary, not just in code (ADR-018).

  On each raw event broadcast:

    1. Load the `%EventRecord{}` via `MtgaLogIngestion.get_event!/1`
    2. Feed it through `IdentifyDomainEvents.translate/2` with the configured
       `mtga_self_user_id`
    3. For each resulting domain event struct, call `Events.append!/2`
    4. Mark the raw event `processed` so it doesn't re-translate on restart

  Translation errors are caught and logged via `MtgaLogIngestion.mark_error!/2`.
  The GenServer never crashes on bad data — malformed events are a
  normal fact of life when mining real logs.

  ## Ordering

  Raw events arrive in the PubSub mailbox in the order `insert_event!/1`
  was called, which matches Player.log byte order. Domain events are
  persisted in the same order (single GenServer → serialized processing).
  This ordering is the basis of `replay_projections!/0` being deterministic.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Config
  alias Scry2.Events
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.EventRecord
  alias Scry2.Topics

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.mtga_logs_events())
    {:ok, %{match_context: %{current_match_id: nil, current_game_number: nil}}}
  end

  @impl true
  def handle_info({:event, %EventRecord{} = record}, state) do
    state =
      try do
        process_raw_event(record, state)
      rescue
        error ->
          Log.error(
            :ingester,
            "failed to process id=#{record.id} type=#{record.event_type}: #{inspect(error)}"
          )

          MtgaLogIngestion.mark_error!(record.id, error)
          state
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Run the raw event through the translator, append each resulting
  # domain event to the log, and update match_context state from the
  # produced events (ADR-022).
  defp process_raw_event(record, state) do
    self_user_id = Config.get(:mtga_self_user_id)
    match_context = state.match_context

    domain_events =
      IdentifyDomainEvents.translate(record, self_user_id, match_context)

    unless IdentifyDomainEvents.recognized?(record.event_type) do
      Log.warning(:ingester, "unrecognized MTGA event type: #{record.event_type}")
    end

    case domain_events do
      [] ->
        MtgaLogIngestion.mark_processed!(record.id)
        state

      events ->
        for event <- events do
          Events.append!(event, record)
        end

        MtgaLogIngestion.mark_processed!(record.id)

        Log.info(
          :ingester,
          "translated raw id=#{record.id} type=#{record.event_type} → #{length(events)} domain events"
        )

        update_match_context(state, events)
    end
  end

  # Update match_context from produced domain events. MatchCreated sets
  # the current match. DeckSubmitted signals a game start (ConnectResp
  # fires per game). MatchCompleted clears both.
  defp update_match_context(state, events) do
    Enum.reduce(events, state, fn
      %Scry2.Events.MatchCreated{mtga_match_id: match_id}, acc ->
        put_in(acc, [:match_context, :current_match_id], match_id)

      %Scry2.Events.DeckSubmitted{}, acc ->
        current_game = get_in(acc, [:match_context, :current_game_number]) || 0
        put_in(acc, [:match_context, :current_game_number], current_game + 1)

      %Scry2.Events.MatchCompleted{}, acc ->
        %{acc | match_context: %{current_match_id: nil, current_game_number: nil}}

      _, acc ->
        acc
    end)
  end
end
