defmodule Scry2.Server.User do
  @moduledoc """
  A server-tier user account (client/server split, ADR-042 Phase 2).

  Holds the `contributes` flag (default true, opt-out) that governs whether the
  user's rows are included in cross-user anonymized aggregates. Auth identity
  (provider deferred) attaches in a later phase. Lives in `Scry2.ServerRepo`
  (Postgres).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "users" do
    field :contributes, :boolean, default: true
    timestamps(type: :utc_datetime)
  end
end
