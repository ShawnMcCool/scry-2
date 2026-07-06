defmodule Scry2.Server.DomainEvent do
  @moduledoc """
  Server-tier persisted domain event (client/server split, ADR-042 Phase 2).

  The shared analytics store's copy of a client domain event: the same domain
  fields plus `user_id` attribution and the content-addressed `upload_key`
  (unique per user). Lives in `Scry2.ServerRepo` (Postgres); `payload` is jsonb.

  Distinct from the client's `Scry2.Events.EventRecord` (SQLite) — the wire
  never carries the client-local `id`/`player_id`; the server assigns its own
  `id` and stamps `user_id` from the authenticated client.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "domain_events" do
    field :user_id, :integer
    field :client_id, :integer
    field :upload_key, :string
    field :event_type, :string
    field :payload, :map
    field :mtga_source_id, :integer
    field :mtga_timestamp, :utc_datetime
    field :sequence, :integer, default: 0
    field :match_id, :string
    field :draft_id, :string
    field :session_id, :string
    field :inserted_at, :utc_datetime
  end
end
