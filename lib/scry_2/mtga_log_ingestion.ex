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
  | 05    | `Scry2.MtgaLogIngestion.insert_events!`        | Batch-persist raw events + signal `mtga_logs:events` |
  | 06    | `Scry2.MtgaLogIngestion.put_cursor!`           | Advance cursor durably (ADR-012)                 |

  Stages 07+ live in `Scry2.Events` and downstream projection contexts,
  consuming via PubSub (ADR-011, ADR-018).

  Each stage is a narrow-contract module; read its `@moduledoc` to see
  the input/output types and why it's shaped the way it is.
  """

  import Ecto.Query

  alias Scry2.Events.RawCompression
  alias Scry2.MtgaLogIngestion.{Cursor, EventRecord}
  alias Scry2.Repo
  alias Scry2.Topics

  # ── Events ──────────────────────────────────────────────────────────────

  @doc """
  Persists a raw parsed event and broadcasts `{:event, record}`.

  Idempotent — if a row with the same `(source_file, log_epoch, file_offset)`
  already exists, the insert is silently skipped and no broadcast fires. This
  prevents duplicate raw events when the watcher re-reads overlapping byte
  ranges after a crash/restart within the same log cycle.

  `log_epoch` distinguishes events from different physical log files that share
  the same path (see ADR-032 — MTGA log rotation). Events from a post-rotation
  Player.log always carry an incremented epoch, so they never collide with events
  from the previous file.
  """
  def insert_event!(attrs) do
    changeset = EventRecord.changeset(%EventRecord{}, compress_raw_json(Map.new(attrs)))

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:source_file, :log_epoch, :file_offset]
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
  Batch-inserts raw parsed events and broadcasts a single catch-up signal.

  Uses `Repo.insert_all` for a single SQL statement instead of per-event
  inserts. Duplicates (same `source_file, log_epoch, file_offset`) are
  silently skipped via `on_conflict: :nothing`.

  After inserting, broadcasts `{:events_inserted, count}` on `mtga_logs:events`
  so `IngestRawEvents` can catch up from its watermark.

  Returns `{inserted_count, nil}`.
  """
  # SQLite bind-variable limit: MAX_VARIABLE_NUMBER=32766 (compiled into
  # the bundled exqlite). Repo.insert_all does NOT auto-split. The
  # rows we build below use 8 columns, so the hard ceiling is 4095 per
  # call. 3_000 keeps comfortable headroom; matches the chunking
  # convention used in `Scry2.Events.append_batch!/1`.
  @insert_chunk_size 3_000

  def insert_events!(events_attrs) when is_list(events_attrs) do
    now = DateTime.utc_now(:second)

    rows =
      Enum.map(events_attrs, fn attrs ->
        attrs
        |> Map.new()
        |> compress_raw_json()
        |> Map.put_new(:inserted_at, now)
        |> Map.put_new(:processed, false)
      end)

    count =
      rows
      |> Enum.chunk_every(@insert_chunk_size)
      |> Enum.reduce(0, fn chunk, acc ->
        {chunk_count, _} =
          Repo.insert_all(EventRecord, chunk,
            on_conflict: :nothing,
            conflict_target: [:source_file, :log_epoch, :file_offset]
          )

        acc + chunk_count
      end)

    # Broadcast outside any caller-held write transaction. Callers that wrap
    # this in `Repo.transaction/1` (e.g. Watcher.drain_file/1) should call
    # `broadcast_inserted/1` themselves after the transaction returns to
    # avoid holding the SQLite write lock during PubSub fan-out.
    if count > 0 and not in_transaction?() do
      broadcast_inserted(count)
    end

    {count, nil}
  end

  @doc """
  Broadcasts `{:events_inserted, count}` on `mtga_logs:events`. Callers that
  invoke `insert_events!/1` inside `Repo.transaction/1` should call this
  after the transaction commits — `insert_events!/1` skips the broadcast
  when invoked inside a transaction.
  """
  def broadcast_inserted(count) when is_integer(count) and count > 0 do
    Topics.broadcast(Topics.mtga_logs_events(), {:events_inserted, count})
  end

  def broadcast_inserted(_), do: :ok

  defp in_transaction?, do: Repo.in_transaction?()

  # zstd-compress the raw_json payload at the write boundary (ADR-042 stage
  # 1a). Idempotent via `ensure_compressed/1`. Handles atom or string keys;
  # leaves attrs without a binary raw_json untouched (the changeset's
  # validate_required surfaces a genuinely missing payload).
  defp compress_raw_json(%{raw_json: raw} = attrs) when is_binary(raw),
    do: %{attrs | raw_json: RawCompression.ensure_compressed(raw)}

  defp compress_raw_json(%{"raw_json" => raw} = attrs) when is_binary(raw),
    do: %{attrs | "raw_json" => RawCompression.ensure_compressed(raw)}

  defp compress_raw_json(attrs), do: attrs

  @doc "Returns unprocessed raw events with id > last_raw_event_id, ordered by id."
  def list_unprocessed_after(last_raw_event_id, opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 1000)

    EventRecord
    |> where([e], e.id > ^last_raw_event_id and e.processed == false)
    |> order_by([e], asc: e.id)
    |> limit(^limit_count)
    |> Repo.all()
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
    message = humanize_error(reason)
    Log.warning(:ingester, "processing error on event #{id}: #{message}")

    {1, _} =
      from(r in EventRecord, where: r.id == ^id)
      |> Repo.update_all(set: [processing_error: message])

    :ok
  end

  defp humanize_error(warnings) when is_list(warnings) do
    warnings
    |> Enum.map(fn
      %{detail: detail} -> detail
      other -> inspect(other)
    end)
    |> Enum.join("; ")
  end

  defp humanize_error(%{message: message}) when is_binary(message), do: message

  defp humanize_error(reason) do
    Exception.message(reason)
  rescue
    _ -> inspect(reason)
  end

  @doc """
  Marks each `{id, reason}` pair as a processing error.

  Errors are rare (malformed events) so individual updates are fine.
  """
  def bulk_mark_errors!(id_reason_pairs) do
    Enum.each(id_reason_pairs, fn {id, reason} -> mark_error!(id, reason) end)
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

    # Emptiness ("{}") can't be tested in SQL anymore: since ADR-042 stage 1a,
    # raw_json is a zstd frame (BLOB) for new rows and plaintext for legacy
    # rows, and SQLite TEXT/BLOB affinity makes a literal comparison both
    # unsupported and unreliable. Decompress and test in Elixir instead. The
    # deferred-type set is small and curated (empty by default), so the row
    # load is bounded.
    from(r in EventRecord, where: r.event_type in ^types, select: {r.event_type, r.raw_json})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {type, raw_json}, acc ->
      if RawCompression.decompress(raw_json) == "{}" do
        acc
      else
        Map.update(acc, type, 1, &(&1 + 1))
      end
    end)
  end

  @doc """
  Returns raw events with id > `cursor`, ordered ascending, up to `limit`.

  Used for cursor-based streaming during retranslation — avoids loading the
  entire raw event table into memory at once.
  """
  def list_ordered_after(cursor, opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 1000)

    EventRecord
    |> where([e], e.id > ^cursor)
    |> order_by([e], asc: e.id)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc """
  Marks only the given event `ids` as processed.

  Used during chunked retranslation to mark each committed batch without
  touching the rest of the table.
  """
  def bulk_mark_processed!(ids) when is_list(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(e in EventRecord, where: e.id in ^ids),
      set: [processed: true, processed_at: now]
    )

    :ok
  end

  @doc "Returns the total number of raw events."
  def count_all do
    Repo.aggregate(EventRecord, :count)
  end

  @doc """
  Deletes raw events older than `cutoff` (exclusive) and returns the number
  removed. Stage 1b retention execution (ADR-042 / ADR-039).

  Deletes ONLY `mtga_logs_events` rows — never domain events. Domain events
  derived from the pruned raw become orphaned (a coverage gap), which
  correctly makes the full-rebuild paths in `Scry2.Events` refuse afterward.
  Manual and gated: nothing calls this on a schedule.
  """
  @spec prune_before!(DateTime.t()) :: non_neg_integer()
  def prune_before!(%DateTime{} = cutoff) do
    {deleted, _} =
      from(e in EventRecord, where: e.mtga_timestamp < ^cutoff)
      |> Repo.delete_all()

    deleted
  end

  @doc "Returns the count of raw events not yet processed."
  def count_unprocessed do
    from(r in EventRecord, where: r.processed == false)
    |> Repo.aggregate(:count)
  end

  @doc "Returns the count of non-dismissed events with a non-nil processing_error."
  def count_errors do
    from(r in EventRecord,
      where: not is_nil(r.processing_error) and is_nil(r.dismissed_at)
    )
    |> Repo.aggregate(:count)
  end

  @doc "Returns recent non-dismissed errored events, newest first."
  def list_errors(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 20)

    from(r in EventRecord,
      where: not is_nil(r.processing_error) and is_nil(r.dismissed_at),
      order_by: [desc: r.id],
      limit: ^limit_count
    )
    |> Repo.all()
  end

  @doc "Permanently dismisses a single processing error by ID."
  def dismiss_error!(id) when is_integer(id) do
    now = DateTime.utc_now(:second)

    {1, _} =
      from(r in EventRecord, where: r.id == ^id)
      |> Repo.update_all(set: [dismissed_at: now])

    :ok
  end

  @doc """
  Returns user-friendly error context for a `processing_error` string.

  Categorizes the stored error message into one of three buckets and returns
  a map with `:title`, `:explanation`, and `:action` keys — suitable for
  display to non-technical end users on the Operations page.

  Categories:
  - `:decode_failure` — the translator found the event but couldn't extract its payload
  - `:missing_field` — an expected field was absent from the event data
  - `:generic` — an unexpected error with no more specific classification
  """
  def user_friendly_error(processing_error) when is_binary(processing_error) do
    describe_error(categorize_error(processing_error))
  end

  defp categorize_error(message) do
    cond do
      String.contains?(message, "failed to decode") -> :decode_failure
      String.contains?(message, ["key :", "enforce_keys", "missing required"]) -> :missing_field
      true -> :generic
    end
  end

  defp describe_error(:decode_failure) do
    %{
      title: "Event data could not be read",
      explanation:
        "Scry2 received a valid event from MTGA Arena but couldn't extract the data it expected. " <>
          "This usually happens after a MTGA client update changes the event format.",
      action:
        "You can safely dismiss this. If it keeps happening after a MTGA update, " <>
          "use \"Export Error Report\" to send the details for diagnosis."
    }
  end

  defp describe_error(:missing_field) do
    %{
      title: "Event was missing expected data",
      explanation:
        "An event from MTGA Arena arrived without a field that Scry2 requires. " <>
          "This is usually caused by a MTGA update changing what data is included.",
      action:
        "You can safely dismiss this. Use \"Export Error Report\" to help diagnose the issue."
    }
  end

  defp describe_error(:generic) do
    %{
      title: "An unexpected error occurred",
      explanation:
        "Scry2 encountered an error while processing an event from MTGA Arena. " <>
          "Your match history has not been affected.",
      action:
        "Use \"Export Error Report\" to send the details. You can dismiss this in the meantime."
    }
  end

  @doc """
  Returns an export-ready map of all current (non-dismissed) errors.

  Parses `raw_json` back to a map so the full MTGA event payload is
  included — this is what you send to the developer to reproduce the issue.
  """
  def export_errors do
    errors = list_errors(limit: 1000)

    %{
      scry2_version: to_string(Application.spec(:scry_2, :vsn)),
      exported_at: DateTime.utc_now(),
      error_count: length(errors),
      errors: Enum.map(errors, &format_error_for_export/1)
    }
  end

  defp format_error_for_export(record) do
    decompressed = RawCompression.decompress(record.raw_json)

    raw_event =
      case Jason.decode(decompressed) do
        {:ok, parsed} -> parsed
        {:error, _} -> decompressed
      end

    %{
      id: record.id,
      event_type: record.event_type,
      occurred_at: record.mtga_timestamp,
      error_summary: record.processing_error,
      raw_event: raw_event
    }
  end

  @doc "Permanently dismisses all current processing errors."
  def dismiss_all_errors! do
    from(r in EventRecord,
      where: not is_nil(r.processing_error) and is_nil(r.dismissed_at)
    )
    |> Repo.update_all(set: [dismissed_at: DateTime.utc_now(:second)])

    :ok
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
