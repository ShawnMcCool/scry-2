defmodule Scry2.Server.Ingest do
  @moduledoc """
  Server-tier ingest of uploaded domain events (client/server split, ADR-042
  Phase 2).

  Takes a `user_id` and a list of decoded wire events (`Scry2.Uplink.WireEvent.decode/1`
  shape) and idempotently upserts them into the shared `domain_events` table,
  keyed on `(user_id, upload_key)`. Re-uploads of an unchanged event no-op; a
  re-upload with a changed `payload` (after a client retranslation) updates the
  row in place — never a duplicate.

  This is the durable heart of the ingest API; the HTTP endpoint (authentication
  → `user_id`) wraps it in a later phase.
  """
  alias Scry2.Server.DomainEvent
  alias Scry2.ServerRepo

  # Columns copied verbatim from the decoded wire event.
  @wire_fields ~w(upload_key event_type payload mtga_source_id mtga_timestamp sequence match_id draft_id session_id)a

  # On an (user_id, upload_key) conflict, replace the mutable domain fields so a
  # retranslated re-upload corrects the stored row. user_id/upload_key/inserted_at
  # are the identity/provenance and are left as first written.
  @replace_on_conflict ~w(event_type payload mtga_source_id mtga_timestamp sequence match_id draft_id session_id)a

  @doc """
  Idempotently upserts `decoded_events` for `user_id`. Returns the number of
  rows inserted-or-updated. Optional `:client_id` stamps provenance.
  """
  @spec ingest_batch(integer(), [map()], keyword()) :: non_neg_integer()
  def ingest_batch(user_id, decoded_events, opts \\ [])

  def ingest_batch(_user_id, [], _opts), do: 0

  def ingest_batch(user_id, decoded_events, opts)
      when is_integer(user_id) and is_list(decoded_events) do
    client_id = Keyword.get(opts, :client_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(decoded_events, fn attrs ->
        attrs
        |> Map.take(@wire_fields)
        |> Map.update(:mtga_timestamp, nil, &truncate_timestamp/1)
        |> Map.put(:user_id, user_id)
        |> Map.put(:client_id, client_id)
        |> Map.put(:inserted_at, now)
      end)

    {count, _} =
      ServerRepo.insert_all(DomainEvent, rows,
        on_conflict: {:replace, @replace_on_conflict},
        conflict_target: [:user_id, :upload_key]
      )

    count
  end

  defp truncate_timestamp(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp truncate_timestamp(other), do: other
end
