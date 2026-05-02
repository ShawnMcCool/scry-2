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
  end
end
