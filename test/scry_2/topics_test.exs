defmodule Scry2.TopicsTest do
  use ExUnit.Case, async: true

  test "updates_status/0 returns a stable string" do
    assert Scry2.Topics.updates_status() == "updates:status"
  end

  test "updates_progress/0 returns a stable string" do
    assert Scry2.Topics.updates_progress() == "updates:progress"
  end
end
