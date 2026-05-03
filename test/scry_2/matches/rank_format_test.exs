defmodule Scry2.Matches.RankFormatTest do
  use ExUnit.Case, async: true

  alias Scry2.Matches.RankFormat

  describe "compose/2" do
    test "returns nil when class is nil" do
      assert RankFormat.compose(nil, nil) == nil
      assert RankFormat.compose(nil, 3) == nil
    end

    test "returns class only when tier is nil" do
      assert RankFormat.compose("Mythic", nil) == "Mythic"
    end

    test "joins class and tier with a space when both present" do
      assert RankFormat.compose("Gold", 3) == "Gold 3"
      assert RankFormat.compose("Diamond", 1) == "Diamond 1"
    end

    test "drops tier for Mythic — MTGA emits tier=1 but it's meaningless at Mythic" do
      assert RankFormat.compose("Mythic", 1) == "Mythic"
      assert RankFormat.compose("Mythic", nil) == "Mythic"
      assert RankFormat.compose("Mythic", 0) == "Mythic"
    end

    test "collapses 'None' sentinel to nil so the UI hides the rank" do
      assert RankFormat.compose("None", 0) == nil
      assert RankFormat.compose("None", nil) == nil
      assert RankFormat.compose("None", 3) == nil
    end
  end
end
