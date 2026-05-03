defmodule Scry2Web.MtgaMemoryHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.MtgaMemoryHelpers, as: H

  describe "format_stats/1" do
    test "formats reads/budget with rounded percent" do
      assert H.format_stats(%{reads_used: 69_168, budget: 200_000}) ==
               "69168 / 200000 (34.6%)"
    end

    test "handles zero budget without dividing by zero" do
      assert H.format_stats(%{reads_used: 5, budget: 0}) == "5 / 0"
    end

    test "renders 100% cleanly" do
      assert H.format_stats(%{reads_used: 200_000, budget: 200_000}) ==
               "200000 / 200000 (100.0%)"
    end
  end

  describe "usage_band/1" do
    test "ok below 50%" do
      assert H.usage_band(%{reads_used: 10, budget: 100}) == :ok
      assert H.usage_band(%{reads_used: 49, budget: 100}) == :ok
    end

    test "watch between 50% and 80%" do
      assert H.usage_band(%{reads_used: 50, budget: 100}) == :watch
      assert H.usage_band(%{reads_used: 79, budget: 100}) == :watch
    end

    test "warning between 80% and 100%" do
      assert H.usage_band(%{reads_used: 80, budget: 100}) == :warning
      assert H.usage_band(%{reads_used: 99, budget: 100}) == :warning
    end

    test "critical at or above 100%" do
      assert H.usage_band(%{reads_used: 100, budget: 100}) == :critical
      assert H.usage_band(%{reads_used: 250, budget: 100}) == :critical
    end
  end

  describe "format_outcome/1" do
    test "ok (no data) for ok-nil" do
      assert H.format_outcome({:ok, nil}) == "ok (no data)"
    end

    test "plain ok for ok-some" do
      assert H.format_outcome({:ok, %{}}) == "ok"
    end

    test "renders error reason inline" do
      assert H.format_outcome({:error, :class_not_found}) =~ "error:"
      assert H.format_outcome({:error, :class_not_found}) =~ "class_not_found"
    end
  end

  describe "outcome_class/1" do
    test "info for ok-nil, success for ok-some, error for error tuple" do
      assert H.outcome_class({:ok, nil}) =~ "badge-info"
      assert H.outcome_class({:ok, %{}}) =~ "badge-success"
      assert H.outcome_class({:error, :anything}) =~ "badge-error"
    end
  end

  describe "match_info_summary/1" do
    test "no opponent screen_name produces (none)" do
      assert H.match_info_summary({:ok, %{opponent: %{screen_name: ""}}}) ==
               "opponent: (none)"
    end

    test "Opponent placeholder counts as none (post-match teardown)" do
      assert H.match_info_summary({:ok, %{opponent: %{screen_name: "Opponent"}}}) ==
               "opponent: (none)"
    end

    test "real screen_name surfaces" do
      assert H.match_info_summary({:ok, %{opponent: %{screen_name: "ProTour9000"}}}) ==
               "opponent: ProTour9000"
    end

    test "appends rank when ranking_class is non-zero" do
      snap = %{opponent: %{screen_name: "x", ranking_class: 4, ranking_tier: 2}}
      assert H.match_info_summary({:ok, snap}) == "opponent: x — rank class=4 tier=2"
    end

    test "no match in progress for ok-nil" do
      assert H.match_info_summary({:ok, nil}) == "no match in progress"
    end
  end

  describe "match_board_summary/1" do
    test "sums arena ids across zones" do
      board = %{
        zones: [
          %{arena_ids: [1, 2, 3]},
          %{arena_ids: [4, 5]}
        ]
      }

      assert H.match_board_summary({:ok, board}) == "zones=2, cards=5"
    end

    test "no match scene for ok-nil" do
      assert H.match_board_summary({:ok, nil}) == "no match scene"
    end
  end

  describe "format_elapsed_ms/1" do
    test "renders sub-ms as <1 ms" do
      assert H.format_elapsed_ms(0) == "<1 ms"
    end

    test "renders integer ms" do
      assert H.format_elapsed_ms(92) == "92 ms"
    end
  end

  describe "truncate_cmdline/2" do
    test "passes short cmdlines through" do
      assert H.truncate_cmdline("short", 100) == "short"
    end

    test "elides middle of long cmdlines" do
      long = String.duplicate("a", 100) <> "/MTGA.exe"
      out = H.truncate_cmdline(long, 40)
      assert String.contains?(out, "...")
      assert byte_size(out) <= 40
    end

    test "handles nil and empty" do
      assert H.truncate_cmdline(nil, 100) == ""
      assert H.truncate_cmdline("", 100) == ""
    end
  end

  describe "normalise_cache_snapshot/1" do
    test "splits the comma-separated slot list per pid" do
      assert H.normalise_cache_snapshot([{901_877, "mono,domain,images,PAPA"}]) ==
               [%{pid: 901_877, slots: ["mono", "domain", "images", "PAPA"]}]
    end

    test "empty rows produce empty list" do
      assert H.normalise_cache_snapshot([]) == []
    end

    test "empty slots string produces empty slots list" do
      assert H.normalise_cache_snapshot([{1, ""}]) ==
               [%{pid: 1, slots: []}]
    end
  end
end
