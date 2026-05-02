defmodule Scry2.LiveState.RankClassTest do
  use ExUnit.Case, async: true

  alias Scry2.LiveState.RankClass

  describe "name/1" do
    test "translates each known enum value to its string name" do
      assert RankClass.name(0) == "None"
      assert RankClass.name(1) == "Bronze"
      assert RankClass.name(2) == "Silver"
      assert RankClass.name(3) == "Gold"
      assert RankClass.name(4) == "Platinum"
      assert RankClass.name(5) == "Diamond"
      assert RankClass.name(6) == "Mythic"
    end

    test "returns nil for nil input" do
      assert RankClass.name(nil) == nil
    end

    test "returns nil for out-of-range integers" do
      assert RankClass.name(-1) == nil
      assert RankClass.name(7) == nil
      assert RankClass.name(99) == nil
    end
  end
end
