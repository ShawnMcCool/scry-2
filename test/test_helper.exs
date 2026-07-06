ExUnit.start(exclude: [:external, :prod_smoke, :server])
Ecto.Adapters.SQL.Sandbox.mode(Scry2.Repo, :manual)

# SERVER tier (client/server split, ADR-042 Phase 2): start the Postgres repo +
# its sandbox ONLY when server tests are requested. Default `mix test` runs stay
# SQLite-only and never touch Postgres. Enable with:
#   docker compose up -d
#   SCRY2_SERVER_TESTS=1 MIX_ENV=test mix test.server
if System.get_env("SCRY2_SERVER_TESTS") == "1" do
  {:ok, _} = Scry2.ServerRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(Scry2.ServerRepo, :manual)
end

# Suppress the "Exqlite.Connection disconnected: client exited" error that
# DBConnection emits when the Sandbox owner process exits during teardown.
# This is normal framework noise — the pool connection reports its checkout
# holder disappeared. Scoped to the DBConnection.Connection module so real
# disconnects from other sources still surface.
:logger.add_primary_filter(:squelch_sandbox_disconnect, {
  fn
    %{meta: %{mfa: {DBConnection.Connection, _, _}}}, _extra -> :stop
    _log, _extra -> :ignore
  end,
  %{}
})
