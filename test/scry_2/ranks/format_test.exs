defmodule Scry2.Ranks.FormatTest do
  use ExUnit.Case, async: true

  alias Scry2.Ranks.Format

  describe "compose/2" do
    test "returns nil when class is nil" do
      assert Format.compose(nil, nil) == nil
      assert Format.compose(nil, 3) == nil
    end

    test "returns class only when tier is nil" do
      assert Format.compose("Mythic", nil) == "Mythic"
    end

    test "joins class and tier with a space when both present" do
      assert Format.compose("Gold", 3) == "Gold 3"
      assert Format.compose("Diamond", 1) == "Diamond 1"
    end

    test "drops tier for Mythic — MTGA emits tier=1 but it's meaningless at Mythic" do
      assert Format.compose("Mythic", 1) == "Mythic"
      assert Format.compose("Mythic", nil) == "Mythic"
      assert Format.compose("Mythic", 0) == "Mythic"
    end

    test "collapses 'None' sentinel to nil so the UI hides the rank" do
      assert Format.compose("None", 0) == nil
      assert Format.compose("None", nil) == nil
      assert Format.compose("None", 3) == nil
    end
  end
end
