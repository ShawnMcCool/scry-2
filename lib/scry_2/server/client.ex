defmodule Scry2.Server.Client do
  @moduledoc """
  A registered capture client for a server-tier user (client/server split,
  ADR-042 Phase 2). Authenticated by a per-client bearer token, stored only as
  a SHA-256 hash. Lives in `Scry2.ServerRepo` (Postgres).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "clients" do
    field :user_id, :integer
    field :token_hash, :string
    field :label, :string
    timestamps(type: :utc_datetime)
  end
end
