defmodule Scry2.ServerCase do
  @moduledoc """
  Test case for the Postgres SERVER tier (client/server split, ADR-042 Phase 2).

  Checks out an `Scry2.ServerRepo` sandbox connection per test. The repo is
  started only when `SCRY2_SERVER_TESTS=1` (see `test/test_helper.exs`), so
  server tests are opt-in: tag them `@moduletag :server` (excluded from the
  default `mix test` run) and invoke via
  `SCRY2_SERVER_TESTS=1 MIX_ENV=test mix test.server` with `docker compose up -d`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Scry2.ServerRepo

      import Ecto
      import Ecto.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Scry2.ServerRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
