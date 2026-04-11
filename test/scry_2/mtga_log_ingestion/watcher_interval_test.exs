defmodule Scry2.MtgaLogIngestion.WatcherIntervalTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogIngestion.Watcher

  describe "clamp_interval/1" do
    test "passes through values inside the valid range" do
      assert Watcher.clamp_interval(500) == 500
      assert Watcher.clamp_interval(100) == 100
      assert Watcher.clamp_interval(10_000) == 10_000
    end

    test "clamps values below the minimum" do
      assert Watcher.clamp_interval(0) == 100
      assert Watcher.clamp_interval(50) == 100
      assert Watcher.clamp_interval(-1) == 100
    end

    test "clamps values above the maximum" do
      assert Watcher.clamp_interval(20_000) == 10_000
      assert Watcher.clamp_interval(1_000_000) == 10_000
    end

    test "falls back to the default when nil" do
      assert Watcher.clamp_interval(nil) == 500
    end

    test "coerces binary integers and falls back on garbage" do
      assert Watcher.clamp_interval("750") == 750
      assert Watcher.clamp_interval("nonsense") == 500
      assert Watcher.clamp_interval("") == 500
    end
  end
end
