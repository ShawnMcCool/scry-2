defmodule Scry2.MtgaLogs do
  @moduledoc """
  Context module for raw MTGA log events and the tail cursor.

  Owns tables: `mtga_logs_events`, `mtga_logs_cursor`.

  PubSub role: broadcasts `"mtga_logs:events"` (parsed events) and
  `"mtga_logs:status"` (watcher state changes).

  Raw log events are the single most important data-integrity invariant
  in Scry2 — every parsed event is persisted with its full raw JSON here
  BEFORE any downstream context consumes it. See ADR-015.
  """

  import Ecto.Query

  alias Scry2.MtgaLogs.{Cursor, EventRecord}
  alias Scry2.Repo
  alias Scry2.Topics

  # ── Events ──────────────────────────────────────────────────────────────

  @doc "Persists a raw parsed event and broadcasts `{:event, id, type}`."
  def insert_event!(attrs) do
    record =
      %EventRecord{}
      |> EventRecord.changeset(Map.new(attrs))
      |> Repo.insert!()

    Topics.broadcast(Topics.mtga_logs_events(), {:event, record.id, record.event_type})
    record
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
