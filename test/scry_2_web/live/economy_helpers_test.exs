defmodule Scry2Web.EconomyHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.EconomyHelpers

  describe "format_currency/2" do
    test "formats amount with label" do
      assert EconomyHelpers.format_currency(1500, "Gems") == "1,500 Gems"
    end

    test "returns dash for nil" do
      assert EconomyHelpers.format_currency(nil, "Gold") == "—"
    end
  end

  describe "format_delta/1" do
    test "positive amounts get plus sign" do
      assert EconomyHelpers.format_delta(500) == "+500"
    end

    test "negative amounts keep minus sign" do
      assert EconomyHelpers.format_delta(-200) == "-200"
    end

    test "zero returns zero" do
      assert EconomyHelpers.format_delta(0) == "0"
    end

    test "nil returns dash" do
      assert EconomyHelpers.format_delta(nil) == "—"
    end
  end

  describe "delta_class/1" do
    test "positive is green" do
      assert EconomyHelpers.delta_class(100) =~ "emerald"
    end

    test "negative is red" do
      assert EconomyHelpers.delta_class(-100) =~ "red"
    end
  end

  describe "format_roi/1" do
    test "in-progress entry" do
      assert EconomyHelpers.format_roi(%{claimed_at: nil}) == "In progress"
    end

    test "gem entry with profit" do
      entry = %{
        entry_fee: 1500,
        entry_currency_type: "Gems",
        gems_awarded: 2000,
        gold_awarded: 1000,
        claimed_at: ~U[2026-04-08 12:00:00Z]
      }

      assert EconomyHelpers.format_roi(entry) == "+500 Gems"
    end

    test "gold entry with loss" do
      entry = %{
        entry_fee: 500,
        entry_currency_type: "Gold",
        gems_awarded: 0,
        gold_awarded: 100,
        claimed_at: ~U[2026-04-08 12:00:00Z]
      }

      assert EconomyHelpers.format_roi(entry) == "-400 Gold"
    end
  end

  describe "format_number/1" do
    test "adds comma separators" do
      assert EconomyHelpers.format_number(1_500_000) == "1,500,000"
    end

    test "small numbers unchanged" do
      assert EconomyHelpers.format_number(42) == "42"
    end

    test "negative numbers" do
      assert EconomyHelpers.format_number(-1500) == "-1,500"
    end
  end
end
