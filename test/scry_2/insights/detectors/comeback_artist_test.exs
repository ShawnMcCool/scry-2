defmodule Scry2.Insights.Detectors.ComebackArtistTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.ComebackArtist
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  defp bo3_match!(match_won, g1_won) do
    match = TestFactory.create_match(%{format_type: "Traditional", won: match_won})
    TestFactory.create_game(%{match: match, game_number: 1, won: g1_won})
    match
  end

  defp many_bo3!(count, match_won, g1_won) do
    Enum.each(1..count, fn _ -> bo3_match!(match_won, g1_won) end)
  end

  describe "tier/0" do
    test "is tier 2" do
      assert ComebackArtist.tier() == 2
    end
  end

  describe "detect/1" do
    test "returns nil with no BO3 matches" do
      assert ComebackArtist.detect([]) == nil
    end

    test "returns nil when fewer than 15 'down 0-1' matches" do
      # 10 down-0-1 matches — below minimum
      many_bo3!(5, true, false)
      many_bo3!(5, false, false)
      many_bo3!(20, true, true)
      assert ComebackArtist.detect([]) == nil
    end

    test "returns nil when fewer than 15 'up 1-0' matches" do
      many_bo3!(20, true, false)
      many_bo3!(5, true, true)
      assert ComebackArtist.detect([]) == nil
    end

    test "returns nil when the two proportions don't differ significantly" do
      # Both arms roughly 50% — no real difference
      many_bo3!(15, true, false)
      many_bo3!(15, false, false)
      many_bo3!(15, true, true)
      many_bo3!(15, false, true)
      assert ComebackArtist.detect([]) == nil
    end

    test "fires when comeback rate is significantly above the 'up 1-0' baseline" do
      # Down 0-1: 25 wins / 30 matches = 83% comeback rate (exceptional)
      many_bo3!(25, true, false)
      many_bo3!(5, false, false)
      # Up 1-0: 30 wins / 60 matches = 50% (mediocre)
      many_bo3!(30, true, true)
      many_bo3!(30, false, true)

      assert %Insight{} = insight = ComebackArtist.detect([])
      assert insight.detector == "ComebackArtist"
      assert insight.tier == 2
      assert insight.measurements["direction"] == "comeback"
      assert insight.measurements["comeback_n"] == 30
      assert insight.measurements["up_1_0_n"] == 60
      assert_in_delta insight.measurements["comeback_wr"], 25 / 30, 0.001
      assert is_float(insight.confidence)
      assert insight.confidence < 0.05
    end

    test "fires when comeback rate is significantly below the 'up 1-0' baseline" do
      # Down 0-1: 3 wins / 30 matches = 10% (very poor)
      many_bo3!(3, true, false)
      many_bo3!(27, false, false)
      # Up 1-0: 50 wins / 60 matches = 83% (strong)
      many_bo3!(50, true, true)
      many_bo3!(10, false, true)

      assert %Insight{} = insight = ComebackArtist.detect([])
      assert insight.measurements["direction"] == "front_runner"
    end

    test "ignores BO1 matches and matches without game 1 records" do
      # Add noise that should not count.
      Enum.each(1..50, fn _ ->
        TestFactory.create_match(%{format_type: "Constructed", won: true})
      end)

      Enum.each(1..50, fn _ ->
        TestFactory.create_match(%{format_type: "Traditional", won: true})
        # No games created — should be filtered out.
      end)

      # Real comeback signal.
      many_bo3!(25, true, false)
      many_bo3!(5, false, false)
      many_bo3!(30, true, true)
      many_bo3!(30, false, true)

      assert %Insight{} = insight = ComebackArtist.detect([])
      assert insight.measurements["comeback_n"] == 30
      assert insight.measurements["up_1_0_n"] == 60
    end

    test "fills stats payload for tile rendering" do
      many_bo3!(25, true, false)
      many_bo3!(5, false, false)
      many_bo3!(30, true, true)
      many_bo3!(30, false, true)

      assert %Insight{stats: stats} = ComebackArtist.detect([])
      assert stats["primary"]["lbl"] == "after 0-1"
      assert stats["secondary"]["lbl"] == "after 1-0"
      assert stats["tertiary"]["num"] == "30"
      assert stats["tertiary"]["lbl"] == "from 0-1"
    end
  end
end
