defmodule Scry2.ReadinessTest do
  use Scry2.DataCase, async: false

  test "check reports ok when the database is reachable and migrations are current" do
    result = Scry2.Readiness.check()

    assert result.status == :ok
    assert result.database == :ok
    assert result.migrations.up_to_date
    assert result.migrations.pending == 0
  end
end
