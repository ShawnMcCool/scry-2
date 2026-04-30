defmodule Scry2.MatchEconomy.TriggerTest do
  use Scry2.DataCase, async: false
  alias Scry2.MatchEconomy
  alias Scry2.MatchEconomy.Trigger

  test "starts and subscribes to domain:events" do
    name = :"trigger_#{System.unique_integer([:positive])}"
    {:ok, pid} = Trigger.start_link(name: name)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  describe "kill switch" do
    test "no summary created when match_economy_capture_enabled is false" do
      Scry2.Settings.put!(MatchEconomy.enabled_settings_key(), false)

      name = :"trigger_kill_#{System.unique_integer([:positive])}"
      {:ok, trigger_pid} = Trigger.start_link(name: name)

      Scry2.Topics.broadcast(
        Scry2.Topics.domain_events(),
        {:domain_event, 1,
         %Scry2.Events.Match.MatchCreated{
           mtga_match_id: "kill-switch-test",
           occurred_at: DateTime.utc_now()
         }}
      )

      # Allow the GenServer's mailbox to drain before asserting.
      :sys.get_state(trigger_pid)

      # Give any task that may have been (incorrectly) spawned time to run.
      Process.sleep(100)

      assert MatchEconomy.get_summary("kill-switch-test") == nil

      GenServer.stop(trigger_pid)
    end
  end
end
