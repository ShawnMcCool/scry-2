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
  | 09    | `Scry2.MatchListing.UpdateFromEvent` | Subscribes, updates `matches_*` projection tables |
  |       | `Scry2.DraftListing.UpdateFromEvent` | (same, for draft projections)                |
  | 10    | `Scry2.MatchListing.upsert_*!`  | Idempotent projection writes                      |
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
  @spec append!(struct(), %Scry2.MtgaLogIngestion.EventRecord{} | nil) :: %EventRecord{}
  def append!(domain_event, source_record) when is_struct(domain_event) do
    attrs = %{
      event_type: Event.type_slug(domain_event),
      payload: struct_to_payload(domain_event),
      mtga_source_id: source_record && source_record.id,
      mtga_timestamp: Event.mtga_timestamp(domain_event)
    }

    {:ok, record} =
      Repo.transaction(fn ->
        %EventRecord{}
        |> EventRecord.changeset(attrs)
        |> Repo.insert!()
      end)

    # Broadcast outside the transaction so subscribers don't observe
    # uncommitted state. The :ok result means the transaction committed.
    Topics.broadcast(Topics.domain_events(), {:domain_event, record.id, record.event_type})

    record
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
      record -> {:ok, rehydrate(record)}
    end
  end

  @doc "Raising variant of `get/1`."
  @spec get!(integer()) :: struct()
  def get!(id) when is_integer(id) do
    id |> (&Repo.get!(EventRecord, &1)).() |> rehydrate()
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
  transaction (Ecto stream requirement). Used by `replay_projections!/0`.
  """
  @spec stream_all() :: Ecto.Query.t()
  def stream_all do
    EventRecord |> order_by([e], asc: e.id)
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

  @doc "Subscribes the calling process to `domain:events`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Topics.subscribe(Topics.domain_events())

  @doc """
  Replays every persisted domain event through the current projectors
  by re-broadcasting them on `domain:events`. Used to rebuild projection
  tables after a projector's logic changes.

  Assumes the caller has already truncated the projection tables (or is
  fine with idempotent upserts overwriting existing rows). Blocks until
  drained by syncing each projector.

  Does not re-run the translator — domain events are read as-is from the
  log. For translator changes, use `retranslate_from_raw!/0` instead.
  """
  @spec replay_projections!() :: :ok
  def replay_projections! do
    # Collect first, broadcast second. Broadcasting inside a Repo.stream
    # transaction can race with projector DB queries for the same
    # connection pool; collecting to a list first keeps the broadcast
    # phase transaction-free. The domain_events table is small enough
    # (thousands of rows max for a heavy user) that buffering is fine.
    records =
      stream_all()
      |> Repo.all()

    Enum.each(records, fn record ->
      Topics.broadcast(Topics.domain_events(), {:domain_event, record.id, record.event_type})
    end)

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

  defp rehydrate(%EventRecord{event_type: "match_created", payload: payload}) do
    %Scry2.Events.MatchCreated{
      mtga_match_id: payload["mtga_match_id"],
      event_name: payload["event_name"],
      opponent_screen_name: payload["opponent_screen_name"],
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "match_completed", payload: payload}) do
    %Scry2.Events.MatchCompleted{
      mtga_match_id: payload["mtga_match_id"],
      occurred_at: parse_datetime(payload["occurred_at"]),
      won: payload["won"],
      num_games: payload["num_games"],
      reason: payload["reason"]
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
      occurred_at: parse_datetime(payload["occurred_at"])
    }
  end

  defp rehydrate(%EventRecord{event_type: "deck_submitted", payload: payload}) do
    %Scry2.Events.DeckSubmitted{
      mtga_match_id: payload["mtga_match_id"],
      mtga_deck_id: payload["mtga_deck_id"],
      main_deck: payload["main_deck"] || [],
      sideboard: payload["sideboard"] || [],
      occurred_at: parse_datetime(payload["occurred_at"])
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

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
