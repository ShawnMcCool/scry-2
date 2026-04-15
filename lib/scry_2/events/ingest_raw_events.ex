defmodule Scry2.Events.IngestRawEvents do
  @moduledoc """
  Pipeline stage 08 — consume raw MTGA events from PubSub, translate to
  domain events, persist to the event log, broadcast to projectors.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:events_inserted, count}` or `{:event, %EventRecord{}}` on `mtga_logs:events` |
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

  `self_user_id` is persisted as part of `IngestionState.session` and
  reloaded on restart. When a `%SessionStarted{}` domain event is
  produced, the `client_id` is captured into state and used for all
  subsequent translations. On a truly fresh install (no persisted
  `ingestion_state` row yet), `self_user_id` starts as `nil` and the
  translator falls back to `systemSeatId: 1` until the first
  `AuthenticateResponse` arrives — after which the pipeline is
  self-configuring for the lifetime of the installation.

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

  alias Scry2.Events
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.IngestionState
  alias Scry2.Events.SnapshotConvert
  alias Scry2.Events.SnapshotDiff
  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.EventRecord
  alias Scry2.Players
  alias Scry2.Topics

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Suspends IngestionState DB persistence. While suspended, in-memory state
  advances normally but is not written to the `ingestion_state` table.
  Used by `Events.reingest!/0` to skip redundant checkpoint writes during
  bulk re-broadcast.
  """
  def suspend_checkpointing(name \\ __MODULE__) do
    GenServer.call(name, :suspend_checkpointing)
  end

  @doc "Resumes IngestionState DB persistence after `suspend_checkpointing/1`."
  def resume_checkpointing(name \\ __MODULE__) do
    GenServer.call(name, :resume_checkpointing)
  end

  @doc """
  Retranslates all raw MTGA events from scratch with synchronous per-event
  progress reporting. Used by `Operations.reingest_with_progress/0`.

  Resets ingestion state to a clean baseline (caller must delete the
  `IngestionState.Snapshot` row first so `IngestionState.load/1` returns
  fresh defaults). Processes every raw event in id order via
  `process_raw_event/3` with checkpointing disabled; persists a single
  checkpoint when the batch is finished.

  `on_progress/2` — a `(processed_count, total_count) -> any()` function
  — is called after every event. This lets callers track exact progress
  without polling.

  This is a synchronous GenServer call that holds the GenServer for the
  entire batch. Use only during a controlled reingest when no other
  callers need the GenServer.
  """
  def retranslate_all!(opts \\ [], name \\ __MODULE__) do
    GenServer.call(name, {:retranslate_all, opts}, :infinity)
  end

  @doc """
  Retranslates all raw events without requiring this GenServer to be running.

  Used by `Events.reingest!/0` during application startup — VersionCheck
  calls reingest! before IngestRawEvents has started in the supervision tree.
  Runs the same DB work as `retranslate_all!/2` but directly in the caller's
  process.
  """
  def retranslate_all_direct!(opts \\ []) do
    final_ingestion = run_retranslation(opts)
    IngestionState.persist!(final_ingestion)
    :ok
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.mtga_logs_events())
    ingestion = IngestionState.load()
    {:ok, %{ingestion: ingestion, checkpointing: true}, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    ingestion = catch_up_unprocessed(state.ingestion)
    {:noreply, %{state | ingestion: ingestion}}
  end

  @impl true
  def handle_call(:suspend_checkpointing, _from, state) do
    {:reply, :ok, %{state | checkpointing: false}}
  end

  @impl true
  def handle_call(:resume_checkpointing, _from, state) do
    {:reply, :ok, %{state | checkpointing: true}}
  end

  # Retranslation processes raw events in cursor-based chunks. The entire chunk —
  # all derived domain events — is committed in one transaction before the next
  # chunk loads. Larger chunks mean fewer round-trips and better throughput.
  #
  # append_batch! (in Events) transparently splits inserts at 3,000 rows to stay
  # under SQLite's MAX_VARIABLE_NUMBER=32766 limit, so this chunk size is not
  # constrained by that ceiling. Increase freely if profiling shows it helps;
  # the only trade-off is peak memory (~1 MB per 1_000 raw events processed).
  @retranslate_chunk_size 5_000

  @impl true
  def handle_call({:retranslate_all, opts}, _from, state) do
    final_ingestion = run_retranslation(opts)
    persisted = IngestionState.persist!(final_ingestion)
    {:reply, :ok, %{state | ingestion: persisted}}
  end

  # Shared retranslation logic used by both retranslate_all!/2 (via GenServer call)
  # and retranslate_all_direct!/1 (direct call during startup).
  # Caller deleted the IngestionState.Snapshot beforehand so load/1 returns defaults,
  # ensuring events are replayed from event 1.
  defp run_retranslation(opts) do
    on_progress = Keyword.get(opts, :on_progress)
    total = MtgaLogIngestion.count_all()
    fresh_ingestion = IngestionState.load()
    do_retranslate_chunk(0, fresh_ingestion, total, 0, on_progress)
  end

  defp do_retranslate_chunk(cursor, ingestion, total, processed, on_progress) do
    case MtgaLogIngestion.list_ordered_after(cursor, limit: @retranslate_chunk_size) do
      [] ->
        ingestion

      records ->
        {new_ingestion, reversed_events, reversed_errors} =
          records
          |> Enum.with_index(processed + 1)
          |> Enum.reduce({ingestion, [], []}, fn {record, index},
                                                 {acc_ingestion, acc_events, acc_errors} ->
            {result_ingestion, new_events, new_errors} =
              try do
                process_raw_event_for_batch(record, acc_ingestion)
              rescue
                error ->
                  Log.error(
                    :ingester,
                    "retranslate_all failed on id=#{record.id}: #{inspect(error)}"
                  )

                  {acc_ingestion, [], [{record.id, error}]}
              end

            if on_progress, do: on_progress.(index, total)
            {result_ingestion, [new_events | acc_events], [new_errors | acc_errors]}
          end)

        event_tuples = reversed_events |> Enum.reverse() |> Enum.concat()
        error_pairs = reversed_errors |> Enum.reverse() |> Enum.concat()
        ids = Enum.map(records, & &1.id)

        try do
          Scry2.Repo.transaction(fn ->
            Events.append_batch!(event_tuples)
            MtgaLogIngestion.bulk_mark_processed!(ids)
            MtgaLogIngestion.bulk_mark_errors!(error_pairs)
          end)
        rescue
          error ->
            Log.error(
              :ingester,
              "retranslate_all transaction failed for batch ending at id=#{List.last(ids)}: #{inspect(error)}"
            )
        end

        do_retranslate_chunk(
          List.last(records).id,
          new_ingestion,
          total,
          processed + length(records),
          on_progress
        )
    end
  end

  @impl true
  def handle_info({:event, %EventRecord{} = record}, state) do
    new_ingestion =
      try do
        process_raw_event(record, state.ingestion, state.checkpointing)
      rescue
        error ->
          if transient_error?(error) do
            Log.warning(
              :ingester,
              "transient error on id=#{record.id} type=#{record.event_type}, will retry on next catch-up: #{inspect(error)}"
            )
          else
            Log.error(
              :ingester,
              "failed to process id=#{record.id} type=#{record.event_type}: #{inspect(error)}"
            )

            MtgaLogIngestion.mark_error!(record.id, error)
          end

          state.ingestion
      end

    {:noreply, %{state | ingestion: new_ingestion}}
  end

  def handle_info({:events_inserted, _count}, state) do
    new_ingestion = catch_up_unprocessed(state.ingestion)
    {:noreply, %{state | ingestion: new_ingestion}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Catch-up ─────────────────────────────────────────────────────────

  defp catch_up_unprocessed(ingestion) do
    unprocessed = MtgaLogIngestion.list_unprocessed_after(ingestion.last_raw_event_id)

    case unprocessed do
      [] ->
        ingestion

      records ->
        Log.info(
          :ingester,
          "catching up #{length(records)} unprocessed raw events from id=#{ingestion.last_raw_event_id}"
        )

        Enum.reduce(records, ingestion, fn record, acc ->
          try do
            process_raw_event(record, acc, true)
          rescue
            error ->
              if transient_error?(error) do
                Log.warning(
                  :ingester,
                  "transient error on catch-up id=#{record.id}, will retry on next catch-up: #{inspect(error)}"
                )
              else
                Log.error(:ingester, "catch-up failed on id=#{record.id}: #{inspect(error)}")
                MtgaLogIngestion.mark_error!(record.id, error)
              end

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
  defp process_raw_event(record, state, checkpointing) do
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

        {new_state, appended} =
          all_events
          |> stamp_player_id(new_state.session.player_id, record)
          |> enrich_events(new_state)
          |> Enum.reduce({new_state, 0, 0}, fn event, {acc_state, sequence, total_appended} ->
            {n_appended, updated_state} =
              maybe_append_event(
                event,
                record,
                sequence,
                new_state.session.current_session_id,
                acc_state
              )

            {updated_state, sequence + n_appended, total_appended + n_appended}
          end)
          |> then(fn {final_state, _sequence, total} -> {final_state, total} end)

        MtgaLogIngestion.mark_processed!(record.id)

        advanced = IngestionState.advance(new_state, record.id)
        new_state = if checkpointing, do: IngestionState.persist!(advanced), else: advanced

        Log.info(
          :ingester,
          "translated raw id=#{record.id} type=#{record.event_type} → #{appended} appended (#{length(all_events)} produced)"
        )

        new_state
    end
  end

  # Batch variant of process_raw_event/3 — same translation and state
  # logic, but returns `{new_ingestion, event_tuples, error_pairs}` instead
  # of writing to the DB. Used by retranslate_all! to accumulate the full
  # translation in memory before committing atomically.
  defp process_raw_event_for_batch(record, state) do
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

    error_pairs =
      if domain_events == [] and translation_warnings != [] and
           IdentifyDomainEvents.recognized?(record.event_type) do
        [{record.id, translation_warnings}]
      else
        []
      end

    case domain_events do
      [] ->
        {state, [], error_pairs}

      events ->
        {new_state, all_events} = apply_events_to_state(state, events)

        {new_state, _sequence, reversed_tuples} =
          all_events
          |> stamp_player_id(new_state.session.player_id, record)
          |> enrich_events(new_state)
          |> Enum.reduce({new_state, 0, []}, fn event, {acc_state, sequence, acc_tuples} ->
            slug = Events.Event.type_slug(event)
            previous_key = acc_state.snapshot_state[slug]

            case SnapshotConvert.convert(event, previous_key) do
              {:converted, new_key, []} ->
                # Snapshot changed but no events to emit; just update state
                updated_state = put_in(acc_state.snapshot_state[slug], new_key)
                {updated_state, sequence, acc_tuples}

              {:converted, new_key, converted_events} ->
                new_tuples =
                  converted_events
                  |> Enum.with_index(sequence)
                  |> Enum.map(fn {converted_event, seq} ->
                    {converted_event, record,
                     [sequence: seq, session_id: new_state.session.current_session_id]}
                  end)

                updated_state = put_in(acc_state.snapshot_state[slug], new_key)
                {updated_state, sequence + length(converted_events), new_tuples ++ acc_tuples}

              :unchanged ->
                {acc_state, sequence, acc_tuples}

              :passthrough ->
                if SnapshotDiff.snapshot_event?(event) do
                  case SnapshotDiff.changed?(event, acc_state.snapshot_state[slug]) do
                    {:changed, key} ->
                      tuple =
                        {event, record,
                         [sequence: sequence, session_id: new_state.session.current_session_id]}

                      updated_state = put_in(acc_state.snapshot_state[slug], key)
                      {updated_state, sequence + 1, [tuple | acc_tuples]}

                    :unchanged ->
                      {acc_state, sequence, acc_tuples}
                  end
                else
                  tuple =
                    {event, record,
                     [sequence: sequence, session_id: new_state.session.current_session_id]}

                  {acc_state, sequence + 1, [tuple | acc_tuples]}
                end
            end
          end)

        event_tuples = Enum.reverse(reversed_tuples)

        Log.info(
          :ingester,
          "translated raw id=#{record.id} type=#{record.event_type} → #{length(event_tuples)} appended (#{length(all_events)} produced)"
        )

        advanced = IngestionState.advance(new_state, record.id)
        {advanced, event_tuples, error_pairs}
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

  # Accumulate instance_id → arena_id mappings from GreToClientEvent messages.
  # MTGA sends gameObjects across many GameStateMessages; we merge them all into
  # state.match.game_objects so the translator can resolve instance IDs to arena_ids
  # even when a later message (e.g. MulliganReq) omits the full gameObjects list.
  defp maybe_cache_game_objects(%EventRecord{event_type: "GreToClientEvent"} = record, state) do
    with {:ok, payload} <- Jason.decode(record.raw_json),
         messages when is_list(messages) <-
           get_in(payload, ["greToClientEvent", "greToClientMessages"]) do
      new_objects =
        messages
        |> Enum.flat_map(fn msg ->
          case get_in(msg, ["gameStateMessage", "gameObjects"]) do
            objects when is_list(objects) ->
              Enum.map(objects, fn obj -> {obj["instanceId"], obj["grpId"]} end)

            _ ->
              []
          end
        end)
        |> Map.new()

      merged = Map.merge(state.match.game_objects, new_objects)
      put_in(state.match.game_objects, merged)
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
  # When the session hasn't seen a SessionStarted yet, falls back to the
  # known player from prior sessions (single-player app).
  defp stamp_player_id(events, player_id, record) do
    resolved_id = player_id || fallback_player_id()

    if is_nil(resolved_id) do
      Log.warning(
        :ingester,
        "no player context for raw id=#{record.id} type=#{record.event_type} — no SessionStarted and no prior player"
      )
    end

    Enum.map(events, fn event -> %{event | player_id: resolved_id} end)
  end

  defp fallback_player_id do
    case Players.list_players() do
      [player | _] -> player.id
      [] -> nil
    end
  end

  # ── Snapshot deduplication and conversion ────────────────────────────

  # Appends domain event(s) to the log, applying snapshot dedup and conversion
  # via SnapshotConvert. Returns `{n_appended, new_state}` where n_appended is
  # the number of events written (0 = skipped, 1+ = appended/converted).
  defp maybe_append_event(event, record, sequence, session_id, state) do
    slug = Events.Event.type_slug(event)
    previous_key = state.snapshot_state[slug]

    case SnapshotConvert.convert(event, previous_key) do
      {:converted, new_key, []} ->
        # Snapshot changed (e.g., position reset) but no domain events to emit
        {0, put_in(state.snapshot_state[slug], new_key)}

      {:converted, new_key, converted_events} ->
        # Append each converted event, assigning sequential sequence numbers
        converted_events
        |> Enum.with_index(sequence)
        |> Enum.each(fn {converted_event, seq} ->
          Events.append!(converted_event, record, sequence: seq, session_id: session_id)
        end)

        {length(converted_events), put_in(state.snapshot_state[slug], new_key)}

      :unchanged ->
        {0, state}

      :passthrough ->
        if SnapshotDiff.snapshot_event?(event) do
          # Pass-through snapshot: use SnapshotDiff for dedup
          case SnapshotDiff.changed?(event, state.snapshot_state[slug]) do
            {:changed, key} ->
              Events.append!(event, record, sequence: sequence, session_id: session_id)
              {1, put_in(state.snapshot_state[slug], key)}

            :unchanged ->
              {0, state}
          end
        else
          # Regular state-change event: always append
          Events.append!(event, record, sequence: sequence, session_id: session_id)
          {1, state}
        end
    end
  end

  # SQLite "Database busy" is a transient infrastructure error — the write lock
  # was held by another operation. These should not be recorded as permanent
  # processing errors. The event stays unprocessed and will be retried on the
  # next catch-up or reingest.
  defp transient_error?(%Exqlite.Error{message: message}) do
    String.contains?(message, "Database busy") or String.contains?(message, "database is locked")
  end

  defp transient_error?(_), do: false
end
