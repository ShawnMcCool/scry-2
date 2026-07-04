defmodule Scry2.Uplink.WireEvent do
  @moduledoc """
  Codec between a persisted domain event (`%Scry2.Events.EventRecord{}`) and
  the self-describing wire message the client uplink ships to the server
  (client/server split, ADR-042 Phase 2).

  The wire message carries the domain fields plus a stable `upload_key`
  (`Scry2.Uplink.UploadKey`). It deliberately omits client-local fields:

    * `id` — a local autoincrement, meaningless on the server (and regenerated
      by retranslation);
    * `player_id` — client-local; the server assigns its own `user_id` from the
      authenticated client, so player attribution never crosses the wire.

  `decode/1` returns an attrs map ready for the server to insert (the server
  stamps `user_id` itself). It is the inverse of `encode/1`.
  """

  alias Scry2.Events.EventRecord
  alias Scry2.Uplink.UploadKey

  @spec encode(EventRecord.t()) :: map()
  def encode(%EventRecord{} = record) do
    %{
      "upload_key" => UploadKey.derive(record),
      "event_type" => record.event_type,
      "payload" => record.payload,
      "mtga_source_id" => record.mtga_source_id,
      "mtga_timestamp" => encode_timestamp(record.mtga_timestamp),
      "sequence" => record.sequence,
      "match_id" => record.match_id,
      "draft_id" => record.draft_id,
      "session_id" => record.session_id
    }
  end

  @spec decode(map()) :: map()
  def decode(%{"upload_key" => upload_key} = wire) do
    %{
      upload_key: upload_key,
      event_type: wire["event_type"],
      payload: wire["payload"],
      mtga_source_id: wire["mtga_source_id"],
      mtga_timestamp: decode_timestamp(wire["mtga_timestamp"]),
      sequence: wire["sequence"],
      match_id: wire["match_id"],
      draft_id: wire["draft_id"],
      session_id: wire["session_id"]
    }
  end

  defp encode_timestamp(nil), do: nil
  defp encode_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_timestamp(nil), do: nil

  defp decode_timestamp(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end
end
