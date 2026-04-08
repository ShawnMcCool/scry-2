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
    2. Feed it through `IdentifyDomainEvents.translate/2` with `self_user_id`
    3. For each resulting domain event struct, call `Events.append!/2`
    4. Mark the raw event `processed` so it doesn't re-translate on restart

  ## Self-user auto-detection

  `self_user_id` is seeded from `Config.get(:mtga_self_user_id)` at init.
  When a `%SessionStarted{}` domain event is produced, the `client_id` is
  captured into GenServer state and used for all subsequent translations.
  This eliminates the need for manual config — the first
  `AuthenticateResponse` in the log auto-detects the player.

  Translation errors are caught and logged via `MtgaLogIngestion.mark_error!/2`.
  The GenServer never crashes on bad data — malformed events are a
  normal fact of life when mining real logs.

  ## Ordering

  Raw events arrive in the PubSub mailbox in the order `insert_event!/1`
  was called, which matches Player.log byte order. Domain events are
  persisted in the same order (single GenServer → serialized processing).
  This ordering is the basis of `replay_projections!/0` being deterministic.

  ## State persistence

  GenServer state is an `%IngestionState{}` struct, persisted to a singleton
  DB row after each raw event. On restart, the state is loaded and any
  unprocessed events after `last_raw_event_id` are caught up before
  processing new PubSub messages.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Config
  alias Scry2.Events
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.IngestionState
  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.EventRecord
  alias Scry2.Players
  alias Scry2.Topics

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.mtga_logs_events())
    state = IngestionState.load(self_user_id: Config.get(:mtga_self_user_id))
    {:ok, state, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    state = catch_up_unprocessed(state)
    {:noreply, state}
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

  # ── Catch-up ─────────────────────────────────────────────────────────

  defp catch_up_unprocessed(state) do
    unprocessed = MtgaLogIngestion.list_unprocessed_after(state.last_raw_event_id)

    case unprocessed do
      [] ->
        state

      records ->
        Log.info(
          :ingester,
          "catching up #{length(records)} unprocessed raw events from id=#{state.last_raw_event_id}"
        )

        Enum.reduce(records, state, fn record, acc ->
          try do
            process_raw_event(record, acc)
          rescue
            error ->
              Log.error(:ingester, "catch-up failed on id=#{record.id}: #{inspect(error)}")
              MtgaLogIngestion.mark_error!(record.id, error)
              acc
          end
        end)
    end
  end

  # ── Core processing ──────────────────────────────────────────────────

  # Run the raw event through the translator, append each resulting
  # domain event to the log, and update state from the produced events.
  #
  # Before translation: cache any gameObjects from this raw event's GRE
  # messages into match state. MTGA sends hand card data (gameObjects)
  # in a GameStateMessage that precedes the MulliganReq. The translator
  # uses cached objects as fallback when the MulliganReq itself lacks them.
  defp process_raw_event(record, state) do
    state = maybe_cache_game_objects(record, state)
    state = maybe_capture_rank(record, state)

    {domain_events, translation_warnings} =
      IdentifyDomainEvents.translate(
        record,
        state.session.self_user_id,
        Map.from_struct(state.match)
      )

    unless IdentifyDomainEvents.recognized?(record.event_type) do
      Log.warning(:ingester, "unrecognized MTGA event type: #{record.event_type}")
    end

    for warning <- translation_warnings do
      Log.warning(
        :ingester,
        "translation: #{warning.category} raw_id=#{record.id} type=#{record.event_type} — #{warning.detail}"
      )
    end

    # If a handled type produced no events but had warnings, record the error
    if domain_events == [] and translation_warnings != [] and
         IdentifyDomainEvents.recognized?(record.event_type) do
      MtgaLogIngestion.mark_error!(record.id, translation_warnings)
    end

    case domain_events do
      [] ->
        MtgaLogIngestion.mark_processed!(record.id)
        state

      events ->
        # Apply each event to IngestionState, collecting side effects
        {new_state, all_events} = apply_events_to_state(state, events)

        all_events
        |> stamp_player_id(new_state.session.player_id, record)
        |> enrich_events(new_state)
        |> Enum.with_index()
        |> Enum.each(fn {event, index} ->
          Events.append!(event, record,
            sequence: index,
            session_id: new_state.session.current_session_id
          )
        end)

        MtgaLogIngestion.mark_processed!(record.id)

        new_state =
          state
          |> Map.get(:last_raw_event_id)
          |> then(fn _ ->
            IngestionState.advance(new_state, record.id) |> IngestionState.persist!()
          end)

        Log.info(
          :ingester,
          "translated raw id=#{record.id} type=#{record.event_type} → #{length(all_events)} domain events"
        )

        new_state
    end
  end

  # Apply each domain event to IngestionState, collecting side effects.
  # For SessionStarted, resolve the player via Players.find_or_create!
  # and set player_id on the session (side effect not in pure apply_event).
  defp apply_events_to_state(state, events) do
    {final_state, collected_events} =
      Enum.reduce(events, {state, []}, fn event, {acc_state, acc_events} ->
        {new_state, side_effects} = IngestionState.apply_event(acc_state, event)

        # SessionStarted: resolve player_id (DB side effect)
        new_state = maybe_resolve_player(new_state, event)

        {new_state, acc_events ++ [event] ++ side_effects}
      end)

    {final_state, collected_events}
  end

  defp maybe_resolve_player(
         state,
         %Scry2.Events.Session.SessionStarted{client_id: client_id, screen_name: screen_name}
       )
       when is_binary(client_id) do
    player = Players.find_or_create!(client_id, screen_name || client_id)

    if state.session.self_user_id != client_id do
      Log.info(:ingester, "auto-detected player: #{player.screen_name} (#{client_id})")
    end

    put_in(state.session.player_id, player.id)
  end

  defp maybe_resolve_player(state, _event), do: state

  # ── Pre-translation state extraction ─────────────────────────────────

  # Cache the player's resolved hand from GreToClientEvent messages.
  # MTGA sends the hand (zone + gameObjects) in a GameStateMessage that
  # often precedes the MulliganReq by several events. The translator
  # uses this cached hand as fallback when the MulliganReq's own
  # GameStateMessage lacks gameObjects or the player's hand zone.
  defp maybe_cache_game_objects(%EventRecord{event_type: "GreToClientEvent"} = record, state) do
    with {:ok, payload} <- Jason.decode(record.raw_json),
         messages when is_list(messages) <-
           get_in(payload, ["greToClientEvent", "greToClientMessages"]),
         {_seat_id, _hand} = resolved <-
           IdentifyDomainEvents.extract_resolved_hand(messages) do
      put_in(state.match.last_hand_game_objects, resolved)
    else
      _ -> state
    end
  end

  defp maybe_cache_game_objects(_record, state), do: state

  # Capture player rank from RankGetCombinedRankInfo events.
  # This fires periodically and on login — we track the latest rank
  # in state and stamp it onto MatchCreated events.
  defp maybe_capture_rank(%EventRecord{event_type: "RankGetCombinedRankInfo"} = record, state) do
    with {:ok, payload} <- Jason.decode(record.raw_json) do
      constructed =
        case {payload["constructedClass"], payload["constructedLevel"]} do
          {class, level} when is_binary(class) and is_integer(level) ->
            "#{class} #{level}"

          _ ->
            state.session.constructed_rank
        end

      limited =
        case {payload["limitedClass"], payload["limitedLevel"]} do
          {class, level} when is_binary(class) and is_integer(level) ->
            "#{class} #{level}"

          _ ->
            state.session.limited_rank
        end

      Log.info(:ingester, "captured rank: constructed=#{constructed} limited=#{limited}")

      %{
        state
        | session: %{state.session | constructed_rank: constructed, limited_rank: limited}
      }
    else
      _ -> state
    end
  end

  defp maybe_capture_rank(_record, state), do: state

  # ── Enrichment & stamping ────────────────────────────────────────────

  # Enrich domain events with derived data (ADR-030).
  # Card metadata, rank, format, hand stats — all computed here so
  # projectors receive fully enriched events with no external lookups.
  defp enrich_events(events, state) do
    Scry2.Events.EnrichEvents.enrich(events, state)
  end

  # Inject player_id into each domain event struct. SessionStarted events
  # set the player_id (they discover the player), so they stamp themselves.
  defp stamp_player_id(events, player_id, record) do
    if is_nil(player_id) do
      Log.warning(
        :ingester,
        "no player context for raw id=#{record.id} type=#{record.event_type} — events before first SessionStarted"
      )
    end

    Enum.map(events, fn event -> %{event | player_id: player_id} end)
  end
end
