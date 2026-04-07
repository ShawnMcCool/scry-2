defmodule Scry2.MtgaLogIngestion do
  @moduledoc """
  Context module for raw MTGA log events and the tail cursor — facade for
  the Player.log ingestion pipeline.

  Owns tables: `mtga_logs_events`, `mtga_logs_cursor`.

  PubSub role: broadcasts `"mtga_logs:events"` (parsed events) and
  `"mtga_logs:status"` (watcher state changes).

  ## The ingestion pipeline

  Raw log events are the single most important data-integrity invariant
  in Scry2 — every parsed event is persisted with its full raw JSON here
  BEFORE any downstream context consumes it (ADR-015).

  The full pipeline, left to right:

  | Stage | Module                                         | Role                                             |
  |-------|------------------------------------------------|--------------------------------------------------|
  | 01    | `Scry2.MtgaLogIngestion.LocateLogFile`         | Find `Player.log` via override or candidate scan |
  | 02    | `Scry2.MtgaLogIngestion.Watcher`               | Subscribe to inotify events, drive the pipeline  |
  | 03    | `Scry2.MtgaLogIngestion.ReadNewBytes`          | Read new bytes since the last cursor offset      |
  | 04    | `Scry2.MtgaLogIngestion.ExtractEventsFromLog`  | Extract `%Event{}` structs from raw log text     |
  | 05    | `Scry2.MtgaLogIngestion.insert_event!`         | Persist raw event + broadcast `mtga_logs:events` |
  | 06    | `Scry2.MtgaLogIngestion.put_cursor!`           | Advance cursor durably (ADR-012)                 |

  Stages 07+ live in `Scry2.Events` and downstream projection contexts,
  consuming via PubSub (ADR-011, ADR-018).

  Each stage is a narrow-contract module; read its `@moduledoc` to see
  the input/output types and why it's shaped the way it is.
  """

  import Ecto.Query

  alias Scry2.MtgaLogIngestion.{Cursor, EventRecord}
  alias Scry2.Repo
  alias Scry2.Topics

  # ── Events ──────────────────────────────────────────────────────────────

  @doc """
  Persists a raw parsed event and broadcasts `{:event, record}`.

  Idempotent — if a row with the same `(source_file, file_offset)` already
  exists, the insert is silently skipped and no broadcast fires. This
  prevents duplicate raw events when the watcher re-reads overlapping byte
  ranges after a crash/restart.
  """
  def insert_event!(attrs) do
    changeset = EventRecord.changeset(%EventRecord{}, Map.new(attrs))

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:source_file, :file_offset]
         ) do
      {:ok, %{id: id} = record} when not is_nil(id) ->
        Topics.broadcast(Topics.mtga_logs_events(), {:event, record})
        record

      {:ok, _record} ->
        # Conflict — row already exists, skip broadcast
        nil
    end
  end

  @doc """
  Returns unprocessed events, oldest first, optionally filtered to a set
  of event types. Used by the ingester GenServers to drain the backlog.
  """
  def list_unprocessed(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 100)
    types = Keyword.get(opts, :types)

    query =
      from r in EventRecord,
        where: r.processed == false,
        order_by: [asc: r.id],
        limit: ^limit_count

    query =
      if types, do: from(r in query, where: r.event_type in ^types), else: query

    Repo.all(query)
  end

  @doc """
  Loads a single raw event record by id. Raises `Ecto.NoResultsError` if
  the id is not found. Used by the matches/drafts ingesters when they
  receive a `{:event, id, type}` message and need to dispatch on the
  event's `raw_json` payload.
  """
  def get_event!(id) when is_integer(id), do: Repo.get!(EventRecord, id)

  @doc "Marks the given event id as processed."
  def mark_processed!(id) when is_integer(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(r in EventRecord, where: r.id == ^id)
      |> Repo.update_all(set: [processed: true, processed_at: now])

    :ok
  end

  @doc "Records a processing error without marking the event as processed."
  def mark_error!(id, reason) when is_integer(id) do
    require Scry2.Log, as: Log
    Log.warning(:ingester, "processing error on event #{id}: #{inspect(reason)}")

    {1, _} =
      from(r in EventRecord, where: r.id == ^id)
      |> Repo.update_all(set: [processing_error: inspect(reason)])

    :ok
  end

  @doc "Returns a map of event_type => count for all persisted events."
  def count_by_type do
    from(r in EventRecord, group_by: r.event_type, select: {r.event_type, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Returns a map of event_type => count for deferred types that have at least one non-empty payload."
  @spec deferred_types_with_payloads(MapSet.t(String.t())) :: %{String.t() => non_neg_integer()}
  def deferred_types_with_payloads(deferred_types) do
    types = MapSet.to_list(deferred_types)

    from(r in EventRecord,
      where: r.event_type in ^types and r.raw_json != "{}",
      group_by: r.event_type,
      select: {r.event_type, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Returns the count of events with a non-nil processing_error."
  def count_errors do
    from(r in EventRecord, where: not is_nil(r.processing_error))
    |> Repo.aggregate(:count)
  end

  @doc "Returns recent errored events, newest first."
  def list_errors(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 20)

    from(r in EventRecord,
      where: not is_nil(r.processing_error),
      order_by: [desc: r.id],
      limit: ^limit_count
    )
    |> Repo.all()
  end

  # ── Cursor ──────────────────────────────────────────────────────────────

  @doc "Returns the cursor row for `file_path`, or nil."
  def get_cursor(file_path) when is_binary(file_path) do
    Repo.get_by(Cursor, file_path: file_path)
  end

  @doc """
  Writes or updates the cursor for `file_path`. Returns the persisted row.
  """
  def put_cursor!(attrs) do
    attrs = Map.new(attrs) |> Map.put_new(:last_read_at, DateTime.utc_now(:second))

    case get_cursor(attrs.file_path) do
      nil -> %Cursor{}
      existing -> existing
    end
    |> Cursor.changeset(attrs)
    |> Repo.insert_or_update!()
  end
end
