ExUnit.start(exclude: [:external, :prod_smoke])
Ecto.Adapters.SQL.Sandbox.mode(Scry2.Repo, :manual)

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
