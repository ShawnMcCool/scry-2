defmodule Scry2Web.RanksHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.RanksHelpers

  describe "format_rank/2" do
    test "formats class and level" do
      assert RanksHelpers.format_rank("Gold", 1) == "Gold 1"
    end

    test "returns class alone when level is nil" do
      assert RanksHelpers.format_rank("Mythic", nil) == "Mythic"
    end

    test "returns dash for nil class" do
      assert RanksHelpers.format_rank(nil, 1) == "—"
    end
  end

  describe "format_record/2" do
    test "formats W-L record" do
      assert RanksHelpers.format_record(10, 5) == "10–5"
    end

    test "returns dash for nil values" do
      assert RanksHelpers.format_record(nil, 5) == "—"
      assert RanksHelpers.format_record(10, nil) == "—"
    end
  end

  describe "step_pips/1" do
    test "returns filled and total pips" do
      assert RanksHelpers.step_pips(3) == {3, 6}
    end

    test "returns zero filled for nil" do
      assert RanksHelpers.step_pips(nil) == {0, 6}
    end
  end
end
