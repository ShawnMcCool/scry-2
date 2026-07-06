defmodule Scry2.ServerRepo do
  @moduledoc """
  Ecto repo for the multi-user SERVER tier (client/server split, ADR-042 Phase 2).

  Postgres-backed, holding the shared analytics dataset (many users' domain
  events, and later projections + aggregates). Deliberately kept OUT of
  `:ecto_repos` and the default application supervisor so the client's
  SQLite-only workflow never depends on Postgres — this repo is started only in
  server mode and in `:server`-tagged tests (see `Scry2.ServerCase`).

  Migrations live in `priv/server_repo/migrations` and run via
  `mix ecto.migrate -r Scry2.ServerRepo` (see the `test.server` mix alias and
  `docker-compose.yml`).
  """
  use Ecto.Repo,
    otp_app: :scry_2,
    adapter: Ecto.Adapters.Postgres
end
