defmodule Scry2.Uplink do
  @moduledoc """
  Client uplink core (client/server split, ADR-042 Phase 2).

  The uplink is a consumer of the append-only `domain_events` log, exactly
  like a projector: it tracks a named cursor over `domain_events.id` and
  yields the events past it, encoded as wire messages (`Scry2.Uplink.WireEvent`)
  for the server ingest API.

  Phase 2a provides only the offline core — batch selection + cursor advance.
  The GenServer, HTTP transport, supervision wiring, config, and the
  retranslation-triggered cursor reset arrive in Phase 2b.

  The cursor is the local `domain_events.id`. A client **retranslation**
  regenerates ids, so Phase 2b will reset this cursor to 0 after a
  retranslate and re-send — the server upserts by `upload_key`, so re-sending
  is idempotent (only changed payloads differ).
  """

  import Ecto.Query

  alias Scry2.Events
  alias Scry2.Events.EventRecord
  alias Scry2.Repo
  alias Scry2.Uplink.WireEvent

  @cursor_name "uplink"
  @default_limit 500

  @doc """
  Returns `{wire_events, new_cursor}` — up to `limit` domain events with
  `id` greater than the stored uplink cursor, encoded as wire messages in
  ascending id order. `new_cursor` is the id of the last event returned, or
  the current cursor when there is nothing new.
  """
  @spec unsent_batch(pos_integer()) :: {[map()], non_neg_integer()}
  def unsent_batch(limit \\ @default_limit) when is_integer(limit) and limit > 0 do
    cursor = Events.get_watermark(@cursor_name)

    records =
      EventRecord
      |> where([e], e.id > ^cursor)
      |> order_by([e], asc: e.id)
      |> limit(^limit)
      |> Repo.all()

    new_cursor =
      case records do
        [] -> cursor
        _ -> List.last(records).id
      end

    {Enum.map(records, &WireEvent.encode/1), new_cursor}
  end

  @doc "Persists the uplink cursor (last domain event id acked by the server)."
  @spec mark_sent!(non_neg_integer()) :: :ok
  def mark_sent!(cursor) when is_integer(cursor) and cursor >= 0 do
    Events.put_watermark!(@cursor_name, cursor)
    :ok
  end

  @doc "Returns the current uplink cursor (0 if nothing has been sent)."
  @spec cursor() :: non_neg_integer()
  def cursor, do: Events.get_watermark(@cursor_name)
end
