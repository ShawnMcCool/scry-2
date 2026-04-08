defmodule Scry2Web.StatsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.StatsHelpers

  describe "format_win_rate/1" do
    test "formats a percentage" do
      assert StatsHelpers.format_win_rate(55.3) == "55.3%"
    end

    test "returns dash for nil" do
      assert StatsHelpers.format_win_rate(nil) == "—"
    end
  end

  describe "win_rate_class/1" do
    test "green above 50" do
      assert StatsHelpers.win_rate_class(55.0) =~ "emerald"
    end

    test "red below 50" do
      assert StatsHelpers.win_rate_class(45.0) =~ "red"
    end

    test "neutral at 50" do
      assert StatsHelpers.win_rate_class(50.0) == "text-base-content"
    end

    test "muted for nil" do
      assert StatsHelpers.win_rate_class(nil) =~ "50"
    end
  end

  describe "format_avg/1" do
    test "formats a float to one decimal" do
      assert StatsHelpers.format_avg(7.333) == "7.3"
    end

    test "returns dash for nil" do
      assert StatsHelpers.format_avg(nil) == "—"
    end
  end

  describe "record/2" do
    test "formats a W-L record" do
      assert StatsHelpers.record(10, 5) == "10–5"
    end
  end
end
