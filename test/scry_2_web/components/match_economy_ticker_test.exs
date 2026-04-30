defmodule Scry2Web.Components.MatchEconomyTickerTest do
  use ExUnit.Case, async: true
  alias Scry2.MatchEconomy.Summary
  alias Scry2Web.Components.MatchEconomyTicker

  describe "totals/1" do
    test "sums currency deltas across summaries" do
      summaries = [
        %Summary{
          memory_gold_delta: 100,
          memory_gems_delta: 0,
          memory_wildcards_common_delta: 1,
          memory_wildcards_uncommon_delta: 0,
          memory_wildcards_rare_delta: 0,
          memory_wildcards_mythic_delta: 0
        },
        %Summary{
          memory_gold_delta: 250,
          memory_gems_delta: 5,
          memory_wildcards_common_delta: 0,
          memory_wildcards_uncommon_delta: 1,
          memory_wildcards_rare_delta: 0,
          memory_wildcards_mythic_delta: 0
        }
      ]

      totals = MatchEconomyTicker.totals(summaries)
      assert totals.gold == 350
      assert totals.gems == 5
      assert totals.wildcards_total == 2
    end

    test "treats nil deltas as zero" do
      summaries = [%Summary{}]
      assert MatchEconomyTicker.totals(summaries) == %{gold: 0, gems: 0, wildcards_total: 0}
    end

    test "empty list yields zero totals" do
      assert MatchEconomyTicker.totals([]) == %{gold: 0, gems: 0, wildcards_total: 0}
    end
  end
end
