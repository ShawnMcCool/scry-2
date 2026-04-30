defmodule Scry2.MatchEconomy.TriggerTest do
  use Scry2.DataCase, async: false
  alias Scry2.MatchEconomy.Trigger

  test "starts and subscribes to domain:events" do
    name = :"trigger_#{System.unique_integer([:positive])}"
    {:ok, pid} = Trigger.start_link(name: name)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
