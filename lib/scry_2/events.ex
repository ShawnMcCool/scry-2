defmodule Scry2.Events do
  @moduledoc """
  Context module for the domain event log — facade for the translation,
  persistence, and distribution layer of the ingestion subsystem. This
  is the anti-corruption boundary between MTGA's wire format and the
  rest of scry_2 (ADR-018).

  Owns table: `domain_events` (append-only).

  PubSub role: broadcasts `"domain:events"` after each successful append.
  Every projector and real-time consumer subscribes here — no downstream
  context touches `mtga_logs_events` directly.

  ## The ingestion subsystem

  Raw MTGA events arrive via the pipeline documented in `Scry2.MtgaLogIngestion`
  (stages 01–06). This context handles stages 07–11:

  | Stage | Module                          | Role                                              |
  |-------|---------------------------------|---------------------------------------------------|
  | 07    | `Scry2.Events.IdentifyDomainEvents` | Pure: raw event record → list of domain events |
  | 08    | `Scry2.Events.IngestRawEvents`     | Subscribes to raw events, calls translator, appends |
  |       | `Scry2.Events.append!/2`        | Persists domain event + broadcasts atomically     |
  | 09    | `Scry2.Matches.UpdateFromEvent` | Subscribes, updates `matches_*` projection tables |
  |       | `Scry2.Drafts.UpdateFromEvent` | (same, for draft projections)                |
  | 10    | `Scry2.Matches.upsert_*!`  | Idempotent projection writes                      |
  | 11    | Context broadcasts              | `matches:updates`, `drafts:updates` (for LiveView)|

  ## Event sourcing guarantees (ADR-017)

    * The `domain_events` table is **append-only**. No update, no delete.
    * Every persisted domain event is a source of truth for its slice of
      domain history.
    * Projection tables (`matches_matches`, `matches_games`, etc.) are
      **derived state**. They can be dropped and rebuilt from the event
      log at any time via `replay_projections!/0`.
    * Raw MTGA events (`mtga_logs_events`) remain the ultimate ground
      truth (ADR-015) — if the translator changes, the domain event log
      itself can be rebuilt via `retranslate_from_raw!/0`.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `Scry2.Events.Event` protocol impls (domain event structs) |
  | **Output** | `{:domain_event, id, type_slug}` broadcasts on `"domain:events"` |
  | **Nature** | Writes to DB; broadcasts via PubSub |
  | **Called from** | `Scry2.Events.IngestRawEvents` (stage 08 → stage 09) |
  | **Hands off to** | Every subscriber of `Scry2.Topics.domain_events/0` |
  """

  import Ecto.Query

  alias Scry2.Events.{Event, EventRecord}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Appends a domain event to the log and broadcasts it on `domain:events`.

  The persist + broadcast run inside a single `Ecto.Multi` transaction —
  the broadcast only fires after the DB commit succeeds, so subscribers
  never see an event that didn't persist.

  `source_record` is the `%Scry2.MtgaLogIngestion.EventRecord{}` that produced
  this domain event (soft reference via `mtga_source_id`); pass `nil`
  for synthetic events that weren't derived from a raw MTGA log entry.

  Returns the persisted `%EventRecord{}` on success.
  """
  @spec append!(struct(), %Scry2.MtgaLogIngestion.EventRecord{} | nil, keyword()) ::
          %EventRecord{} | nil
  def append!(domain_event, source_record, opts \\ []) when is_struct(domain_event) do
    type_slug = Event.type_slug(domain_event)
    source_id = source_record && source_record.id
    sequence = Keyword.get(opts, :sequence, 0)
    session_id = Keyword.get(opts, :session_id)

    attrs = %{
      event_type: type_slug,
      payload: struct_to_payload(domain_event),
      mtga_source_id: source_id,
      mtga_timestamp: Event.mtga_timestamp(domain_event),
      sequence: sequence,
      player_id: Map.get(domain_event, :player_id),
      match_id: Map.get(domain_event, :mtga_match_id),
      draft_id: Map.get(domain_event, :mtga_draft_id),
      session_id: session_id
    }

    changeset = EventRecord.changeset(%EventRecord{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:mtga_source_id, :event_type, :sequence]
         ) do
      {:ok, %{id: id} = record} when not is_nil(id) ->
        Topics.broadcast(Topics.domain_events(), {:domain_event, record.id, record.event_type})
        record

      {:ok, _record} ->
        # Conflict — domain event already exists, skip broadcast
        nil
    end
  end

  @doc """
  Loads a domain event record by id and rehydrates it into the original
  struct form. Returns `{:ok, struct}` or `{:error, :not_found}`.

  Projectors use this to get a typed struct back from the `{:domain_event, id, type}`
  broadcast message.
  """
  @spec get(integer()) :: {:ok, struct()} | {:error, :not_found}
  def get(id) when is_integer(id) do
    case Repo.get(EventRecord, id) do
      nil -> {:error, :not_found}
      record -> {:ok, rehydrate_with_metadata(record)}
    end
  end

  @doc "Raising variant of `get/1`."
  @spec get!(integer()) :: struct()
  def get!(id) when is_integer(id) do
    Repo.get!(EventRecord, id) |> rehydrate_with_metadata()
  end

  @doc """
  Returns all domain events with id > `since_id`, ordered by id ascending.
  Used by rebuild tooling to replay events incrementally.
  """
  @spec list_since(non_neg_integer()) :: [%EventRecord{}]
  def list_since(since_id) when is_integer(since_id) and since_id >= 0 do
    EventRecord
    |> where([e], e.id > ^since_id)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end

  @doc """
  Streams every domain event in id order. Must be called inside a
  transaction (Ecto stream requirement).
  """
  @spec stream_all() :: Ecto.Query.t()
  def stream_all do
    EventRecord |> order_by([e], asc: e.id)
  end

  @doc """
  Fetches domain events of the given types in batches, ordered by id.
  Calls `fun` with each rehydrated event struct. Cursor-based — fetches
  `batch_size` rows at a time starting from id 0.

  Used by projectors for self-owned replay (ADR-029). No PubSub involved.

  ## Example

      Events.replay_by_types(~w(match_created match_completed), fn event ->
        project(event)
      end)
  """
  @spec replay_by_types([String.t()], (struct() -> any()), keyword()) :: :ok
  def replay_by_types(type_slugs, fun, opts \\ [])
      when is_list(type_slugs) and is_function(fun, 1) do
    batch_size = Keyword.get(opts, :batch_size, 500)
    do_replay_by_types(type_slugs, fun, batch_size, 0)
  end

  defp do_replay_by_types(type_slugs, fun, batch_size, cursor) do
    batch =
      EventRecord
      |> where([e], e.event_type in ^type_slugs and e.id > ^cursor)
      |> order_by([e], asc: e.id)
      |> limit(^batch_size)
      |> Repo.all()

    case batch do
      [] ->
        :ok

      records ->
        Enum.each(records, fn record ->
          fun.(rehydrate_with_metadata(record))
        end)

        last_id = List.last(records).id
        do_replay_by_types(type_slugs, fun, batch_size, last_id)
    end
  end

  @doc "Returns a map of event_type slug => count. Diagnostics only."
  @spec count_by_type() :: %{String.t() => non_neg_integer()}
  def count_by_type do
    EventRecord
    |> group_by([e], e.event_type)
    |> select([e], {e.event_type, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Lists domain events matching the given filters, with pagination.

  Returns `{events, total_count}` where events are rehydrated typed structs.

  ## Supported filters

    * `:event_types` — list of type slugs, e.g. `["match_created", "game_completed"]`
    * `:since` — `%DateTime{}`, lower bound on `mtga_timestamp` (inclusive)
    * `:until` — `%DateTime{}`, upper bound on `mtga_timestamp` (inclusive)
    * `:text_search` — string, `LIKE` search on serialized payload
    * `:match_id` — string, filter by match correlation
    * `:draft_id` — string, filter by draft correlation
    * `:session_id` — string, filter by session correlation
    * `:player_id` — integer, filter by player
    * `:limit` — integer, default 50
    * `:offset` — integer, default 0
  """
  @spec list_events(keyword()) :: {[struct()], non_neg_integer()}
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    base_query = opts |> build_filter_query()

    total_count = Repo.aggregate(base_query, :count)

    events =
      base_query
      |> order_by([e], desc: e.mtga_timestamp, desc: e.id)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
      |> Enum.map(&rehydrate_with_metadata/1)

    {events, total_count}
  end

  defp build_filter_query(opts) do
    EventRecord
    |> maybe_filter_event_types(opts[:event_types])
    |> maybe_filter_since(opts[:since])
    |> maybe_filter_until(opts[:until])
    |> maybe_filter_text_search(opts[:text_search])
    |> maybe_filter_match_id(opts[:match_id])
    |> maybe_filter_draft_id(opts[:draft_id])
    |> maybe_filter_session_id(opts[:session_id])
    |> maybe_filter_player_id(opts[:player_id])
  end

  defp maybe_filter_event_types(query, nil), do: query
  defp maybe_filter_event_types(query, []), do: query
  defp maybe_filter_event_types(query, types), do: where(query, [e], e.event_type in ^types)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [e], e.mtga_timestamp >= ^since)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until_dt), do: where(query, [e], e.mtga_timestamp <= ^until_dt)

  defp maybe_filter_text_search(query, nil), do: query
  defp maybe_filter_text_search(query, ""), do: query

  defp maybe_filter_text_search(query, text) do
    pattern = "%#{text}%"
    where(query, [e], fragment("CAST(? AS TEXT) LIKE ?", e.payload, ^pattern))
  end

  defp maybe_filter_match_id(query, nil), do: query
  defp maybe_filter_match_id(query, match_id), do: where(query, [e], e.match_id == ^match_id)

  defp maybe_filter_draft_id(query, nil), do: query
  defp maybe_filter_draft_id(query, draft_id), do: where(query, [e], e.draft_id == ^draft_id)

  defp maybe_filter_session_id(query, nil), do: query

  defp maybe_filter_session_id(query, session_id),
    do: where(query, [e], e.session_id == ^session_id)

  defp maybe_filter_player_id(query, nil), do: query
  defp maybe_filter_player_id(query, player_id), do: where(query, [e], e.player_id == ^player_id)

  @doc """
  Lists all mulligan_offered events, rehydrated as typed structs.

  Supports `:player_id` and `:match_id` filters.
  Returns events ordered by `mtga_timestamp` descending.
  """
  @spec list_mulligans(keyword()) :: [struct()]
  def list_mulligans(opts \\ []) do
    EventRecord
    |> where([e], e.event_type == "mulligan_offered")
    |> maybe_filter_player_id(opts[:player_id])
    |> maybe_filter_match_id(opts[:match_id])
    |> order_by([e], desc: e.mtga_timestamp, desc: e.id)
    |> Repo.all()
    |> Enum.map(&rehydrate_with_metadata/1)
  end

  @doc "Subscribes the calling process to `domain:events`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Topics.subscribe(Topics.domain_events())

  @doc """
  Full reingest — clears all derived data and rebuilds from raw MTGA events.

  1. Deletes all projections (matches, drafts, deck submissions, etc.)
  2. Deletes all domain events
  3. Re-marks raw events as unprocessed
  4. Re-broadcasts each raw event for `IngestRawEvents` to retranslate

  Call this whenever the translator has changed or domain events need
  to be regenerated from scratch. Safe to call at any time — raw MTGA
  events are never deleted.

  Requires `IngestRawEvents` to be running (it is in the default
  supervision tree). Blocks until all raw events have been re-broadcast.
  """
  @spec reingest!() :: :ok
  def reingest! do
    require Scry2.Log, as: Log
    Log.info(:ingester, "reingest: starting full reingest from raw events")

    # 1. Clear domain events (projections are cleared by rebuild! later)
    Repo.delete_all(EventRecord)

    # 2. Re-mark raw events as unprocessed
    {raw_count, _} =
      Scry2.MtgaLogIngestion.EventRecord
      |> Repo.update_all(set: [processed: false, processed_at: nil, processing_error: nil])

    # 3. Re-broadcast each raw event for retranslation via IngestRawEvents
    Scry2.MtgaLogIngestion.EventRecord
    |> order_by([e], asc: e.id)
    |> Repo.all()
    |> Enum.each(fn raw ->
      Topics.broadcast(Topics.mtga_logs_events(), {:event, raw})
    end)

    Log.info(:ingester, "reingest: re-broadcast #{raw_count} raw events for retranslation")

    # 4. Rebuild all projections from the freshly-translated domain events.
    #    Each projector queries the event store directly (ADR-029) — no
    #    PubSub race conditions.
    #
    #    Note: the retranslation above is async (IngestRawEvents GenServer),
    #    but the domain events are written synchronously within each
    #    handle_info. By the time we reach this line, all broadcasts have
    #    been sent and the GenServer's mailbox will process them in order.
    #    We sync by calling GenServer to drain its mailbox first.
    sync_ingest_raw_events()
    replay_projections!()

    :ok
  end

  # Ensures IngestRawEvents has processed all queued messages by
  # sending a synchronous call that must be handled after all prior
  # handle_info messages in the mailbox.
  defp sync_ingest_raw_events do
    case Process.whereis(Scry2.Events.IngestRawEvents) do
      nil -> :ok
      pid -> :sys.get_state(pid) && :ok
    end
  end

  @doc """
  Rebuilds all projection tables from the domain event store.

  Each projector owns its own replay (ADR-029): truncates its tables,
  queries the event store for its claimed types in id order, and
  processes them sequentially. No PubSub involved — deterministic and
  race-free.

  Does not re-run the translator — domain events are read as-is from
  the log. For translator changes, use `reingest!/0` instead.
  """
  @spec replay_projections!() :: :ok
  def replay_projections! do
    require Scry2.Log, as: Log
    Log.info(:ingester, "replay_projections: rebuilding all projections from event store")

    Scry2.Matches.UpdateFromEvent.rebuild!()
    Scry2.Drafts.UpdateFromEvent.rebuild!()
    Scry2.Mulligans.UpdateFromEvent.rebuild!()
    Scry2.MatchListing.UpdateFromEvent.rebuild!()

    Log.info(:ingester, "replay_projections: all projections rebuilt")
    :ok
  end

  @doc """
  Rebuilds the domain event log from raw MTGA events. Truncates
  `domain_events`, resets the `processed` flag on every raw event, and
  lets the `IngestRawEvents` re-translate from scratch (by re-broadcasting
  each raw event on `mtga_logs:events`).

  Use when the `Scry2.Events.IdentifyDomainEvents` has changed and historical
  domain events need to be regenerated.
  """
  @spec retranslate_from_raw!() :: :ok
  def retranslate_from_raw! do
    Repo.delete_all(EventRecord)

    Scry2.MtgaLogIngestion.EventRecord
    |> Repo.update_all(set: [processed: false, processed_at: nil, processing_error: nil])

    Scry2.MtgaLogIngestion.EventRecord
    |> order_by([e], asc: e.id)
    |> Repo.all()
    |> Enum.each(fn raw ->
      Topics.broadcast(Topics.mtga_logs_events(), {:event, raw})
    end)

    :ok
  end

  @doc """
  Clears domain events and all projections, then re-marks raw events as
  unprocessed so they can be replayed through the pipeline.

  Raw MTGA events (`mtga_logs_events`) are the permanent source of truth
  (ADR-015) and are never deleted by this function. After calling this,
  restart `IngestRawEvents` (and the watcher if raw events also need
  re-reading from the log file) to trigger replay.

  Use `reset_raw!()` for the exceptional case where raw event data itself
  is corrupt and needs to be re-ingested from Player.log.
  """
  @spec reset_all!() :: :ok
  def reset_all! do
    require Scry2.Log, as: Log
    Log.info(:ingester, "reset_all: clearing domain events and all projections")

    # Clear domain events
    Repo.delete_all(EventRecord)

    # Each projector clears its own tables (ADR-029)
    Scry2.Matches.UpdateFromEvent.rebuild!()
    Scry2.Drafts.UpdateFromEvent.rebuild!()
    Scry2.Mulligans.UpdateFromEvent.rebuild!()
    Scry2.MatchListing.UpdateFromEvent.rebuild!()

    # Re-mark raw events as unprocessed so replay picks them up
    Scry2.MtgaLogIngestion.EventRecord
    |> Repo.update_all(set: [processed: false, processed_at: nil, processing_error: nil])

    :ok
  end

  @doc """
  Nuclear reset — clears ALL data including raw events and cursor.
  Forces the watcher to re-read Player.log from byte 0.

  Only use when raw event parsing/storage is known to be broken.
  Prefer `reset_all!/0` for normal replay scenarios.
  """
  @spec reset_raw!() :: :ok
  def reset_raw! do
    reset_all!()
    Repo.delete_all(Scry2.MtgaLogIngestion.EventRecord)
    Repo.delete_all(Scry2.MtgaLogIngestion.Cursor)

    :ok
  end

  # ── Serialization ────────────────────────────────────────────────────
  #
  # Domain events are stored as JSON payloads keyed by slug. Rehydration
  # is a case dispatch on the stored slug — each case builds the right
  # struct with the right key atoms.

  defp struct_to_payload(domain_event) do
    domain_event
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), serialize_value(v)} end)
    |> Map.new()
  end

  # Serialize DateTimes as ISO8601 strings; Jason handles the rest.
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(value), do: value

  defp rehydrate_with_metadata(%EventRecord{} = record) do
    event = rehydrate(record)
    event = %{event | player_id: record.player_id}
    Map.put(event, :id, record.id)
  end

  defp rehydrate(%EventRecord{event_type: "match_created", payload: payload}) do
    %Scry2.Events.MatchCreated{
      mtga_match_id: payload["mtga_match_id"],
      event_name: payload["event_name"],
      opponent_screen_name: payload["opponent_screen_name"],
      opponent_user_id: payload["opponent_user_id"],
      platform: payload["platform"],
      opponent_platform: payload["opponent_platform"],
      occurred_at: parse_datetime(payload["occurred_at"]),
      player_rank: payload["player_rank"],
      format: payload["format"],
      format_type: payload["format_type"]
    }
  end

  defp rehydrate(%EventRecord{event_type: "match_completed", payload: payload}) do
    %Scry2.Events.MatchCompleted{
      mtga_match_id: payload["mtga_match_id"],
      occurred_at: parse_datetime(payload["occurred_at"]),
      won: payload["won"],
      num_games: payload["num_games"],
      reason: payload["reason"],
      game_results: payload["game_results"]
    }
  end

  defp rehydrate(%EventRecord{event_type: "game_completed", payload: payload}) do
    %Scry2.Events.GameCompleted{
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      on_play: payload["on_play"],
      won: payload["won"],
      num_mulligans: payload["num_mulligans"],
      num_turns: payload["num_turns"],
      self_life_total: payload["self_life_total"],
      opponent_life_total: payload["opponent_life_total"],
      win_reason: payload["win_reason"],
      super_format: payload["super_format"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "deck_submitted", payload: payload}) do
    %Scry2.Events.DeckSubmitted{
      mtga_match_id: payload["mtga_match_id"],
      mtga_deck_id: payload["mtga_deck_id"],
      main_deck: payload["main_deck"] || [],
      sideboard: payload["sideboard"] || [],
      occurred_at: parse_datetime(payload["occurred_at"]),
      deck_colors: payload["deck_colors"]
    }
  end

  defp rehydrate(%EventRecord{event_type: "draft_started", payload: payload}) do
    %Scry2.Events.DraftStarted{
      mtga_draft_id: payload["mtga_draft_id"],
      event_name: payload["event_name"],
      set_code: payload["set_code"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "draft_pick_made", payload: payload}) do
    %Scry2.Events.DraftPickMade{
      mtga_draft_id: payload["mtga_draft_id"],
      pack_number: payload["pack_number"],
      pick_number: payload["pick_number"],
      picked_arena_id: payload["picked_arena_id"],
      pack_arena_ids: payload["pack_arena_ids"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "die_roll_completed", payload: payload}) do
    %Scry2.Events.DieRollCompleted{
      mtga_match_id: payload["mtga_match_id"],
      self_roll: payload["self_roll"],
      opponent_roll: payload["opponent_roll"],
      self_goes_first: payload["self_goes_first"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "mulligan_offered", payload: payload}) do
    %Scry2.Events.MulliganOffered{
      mtga_match_id: payload["mtga_match_id"],
      seat_id: payload["seat_id"],
      hand_size: payload["hand_size"],
      hand_arena_ids: payload["hand_arena_ids"],
      occurred_at: parse_datetime(payload["occurred_at"]),
      land_count: payload["land_count"],
      nonland_count: payload["nonland_count"],
      total_cmc: payload["total_cmc"],
      cmc_distribution: payload["cmc_distribution"],
      color_distribution: payload["color_distribution"],
      card_names: payload["card_names"]
    }
  end

  defp rehydrate(%EventRecord{event_type: "rank_snapshot", payload: payload}) do
    %Scry2.Events.RankSnapshot{
      constructed_class: payload["constructed_class"],
      constructed_level: payload["constructed_level"],
      constructed_step: payload["constructed_step"],
      constructed_matches_won: payload["constructed_matches_won"],
      constructed_matches_lost: payload["constructed_matches_lost"],
      limited_class: payload["limited_class"],
      limited_level: payload["limited_level"],
      limited_step: payload["limited_step"],
      limited_matches_won: payload["limited_matches_won"],
      limited_matches_lost: payload["limited_matches_lost"],
      season_ordinal: payload["season_ordinal"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "session_started", payload: payload}) do
    %Scry2.Events.SessionStarted{
      client_id: payload["client_id"],
      screen_name: payload["screen_name"],
      session_id: payload["session_id"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "event_joined", payload: payload}) do
    %Scry2.Events.EventJoined{
      event_name: payload["event_name"],
      course_id: payload["course_id"],
      entry_currency_type: payload["entry_currency_type"],
      entry_fee: payload["entry_fee"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "inventory_changed", payload: payload}) do
    %Scry2.Events.InventoryChanged{
      source: payload["source"],
      source_id: payload["source_id"],
      gold_delta: payload["gold_delta"],
      gems_delta: payload["gems_delta"],
      boosters: payload["boosters"],
      gold_balance: payload["gold_balance"],
      gems_balance: payload["gems_balance"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "prize_claimed", payload: payload}) do
    %Scry2.Events.PrizeClaimed{
      event_name: payload["event_name"],
      course_id: payload["course_id"],
      wins: payload["wins"],
      losses: payload["losses"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "deck_selected", payload: payload}) do
    %Scry2.Events.DeckSelected{
      event_name: payload["event_name"],
      deck_id: payload["deck_id"],
      deck_name: payload["deck_name"],
      main_deck: payload["main_deck"] || [],
      sideboard: payload["sideboard"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "pairing_entered", payload: payload}) do
    %Scry2.Events.PairingEntered{
      event_name: payload["event_name"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "quest_status", payload: payload}) do
    %Scry2.Events.QuestStatus{
      quests: payload["quests"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "daily_wins_status", payload: payload}) do
    %Scry2.Events.DailyWinsStatus{
      daily_position: payload["daily_position"],
      daily_reset_at: payload["daily_reset_at"],
      weekly_position: payload["weekly_position"],
      weekly_reset_at: payload["weekly_reset_at"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "active_courses", payload: payload}) do
    %Scry2.Events.ActiveCourses{
      courses: payload["courses"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "deck_inventory", payload: payload}) do
    %Scry2.Events.DeckInventory{
      decks: payload["decks"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "deck_updated", payload: payload}) do
    %Scry2.Events.DeckUpdated{
      deck_id: payload["deck_id"],
      deck_name: payload["deck_name"],
      format: payload["format"],
      action_type: payload["action_type"],
      main_deck: payload["main_deck"] || [],
      sideboard: payload["sideboard"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "mastery_progress", payload: payload}) do
    %Scry2.Events.MasteryProgress{
      node_states: payload["node_states"],
      milestone_states: payload["milestone_states"],
      total_nodes: payload["total_nodes"],
      completed_nodes: payload["completed_nodes"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "inventory_updated", payload: payload}) do
    %Scry2.Events.InventoryUpdated{
      gold: payload["gold"],
      gems: payload["gems"],
      wildcards_common: payload["wildcards_common"],
      wildcards_uncommon: payload["wildcards_uncommon"],
      wildcards_rare: payload["wildcards_rare"],
      wildcards_mythic: payload["wildcards_mythic"],
      vault_progress: payload["vault_progress"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "event_course_updated", payload: payload}) do
    %Scry2.Events.EventCourseUpdated{
      event_name: payload["event_name"],
      current_wins: payload["current_wins"],
      current_losses: payload["current_losses"],
      current_module: payload["current_module"],
      card_pool: payload["card_pool"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "event_reward_claimed", payload: payload}) do
    %Scry2.Events.EventRewardClaimed{
      event_name: payload["event_name"],
      final_wins: payload["final_wins"],
      final_losses: payload["final_losses"],
      gems_awarded: payload["gems_awarded"],
      gold_awarded: payload["gold_awarded"],
      boosters_awarded: payload["boosters_awarded"],
      card_pool: payload["card_pool"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "game_action", payload: payload}) do
    %Scry2.Events.GameAction{
      mtga_match_id: payload["mtga_match_id"],
      action: payload["action"],
      decision: payload["decision"],
      chose_play: payload["chose_play"],
      scope: payload["scope"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
