defmodule Scry2Web.DashboardHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DashboardHelpers, as: H

  describe "watcher_label/1" do
    test "maps known states to human labels" do
      assert H.watcher_label(%{state: :running}) == "Running"
      assert H.watcher_label(%{state: :starting}) == "Starting..."
      assert H.watcher_label(%{state: :path_not_found}) == "Path not found"
      assert H.watcher_label(%{state: :not_running}) == "Stopped"
    end

    test "falls back to Unknown for anything else" do
      assert H.watcher_label(%{state: :frobnicated}) == "Unknown"
      assert H.watcher_label(%{}) == "Unknown"
    end
  end

  describe "show_detailed_logs_warning?/1" do
    test "shows warning when the path is unknown or missing" do
      assert H.show_detailed_logs_warning?(%{state: :path_not_found})
      assert H.show_detailed_logs_warning?(%{state: :path_missing})
      assert H.show_detailed_logs_warning?(%{state: :not_running})
    end

    test "hides warning when the watcher is running" do
      refute H.show_detailed_logs_warning?(%{state: :running})
      refute H.show_detailed_logs_warning?(%{state: :starting})
    end
  end

  describe "sort_events_by_count/1" do
    test "sorts events by count descending" do
      events = %{"MatchStart" => 5, "DraftPack" => 20, "MatchEnd" => 5}
      sorted = H.sort_events_by_count(events)

      assert [{"DraftPack", 20} | _] = sorted
      assert length(sorted) == 3
    end

    test "returns [] for empty input" do
      assert H.sort_events_by_count(%{}) == []
    end
  end
end
