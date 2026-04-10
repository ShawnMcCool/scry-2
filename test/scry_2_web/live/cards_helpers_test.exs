defmodule Scry2Web.CardsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.CardsHelpers, as: H

  describe "any_filter_active?/5" do
    test "returns false when all filters are empty" do
      refute H.any_filter_active?("", MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new())
    end

    test "returns true when search is non-empty" do
      assert H.any_filter_active?("bolt", MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new())
    end

    test "returns true when colors has entries" do
      assert H.any_filter_active?("", MapSet.new(["R"]), MapSet.new(), MapSet.new(), MapSet.new())
    end

    test "returns true when rarities has entries" do
      assert H.any_filter_active?(
               "",
               MapSet.new(),
               MapSet.new(["mythic"]),
               MapSet.new(),
               MapSet.new()
             )
    end

    test "returns true when mana_values has entries" do
      assert H.any_filter_active?("", MapSet.new(), MapSet.new(), MapSet.new([3]), MapSet.new())
    end

    test "returns true when types has entries" do
      assert H.any_filter_active?(
               "",
               MapSet.new(),
               MapSet.new(),
               MapSet.new(),
               MapSet.new([:creature])
             )
    end
  end

  describe "blank_to_nil/1" do
    test "converts empty string to nil" do
      assert H.blank_to_nil("") == nil
    end

    test "converts nil to nil" do
      assert H.blank_to_nil(nil) == nil
    end

    test "passes through non-empty strings" do
      assert H.blank_to_nil("bolt") == "bolt"
    end
  end

  describe "rarity_filter/1" do
    test "returns nil for empty set" do
      assert H.rarity_filter(MapSet.new()) == nil
    end

    test "returns single string for one rarity" do
      assert H.rarity_filter(MapSet.new(["mythic"])) == "mythic"
    end

    test "returns list for multiple rarities" do
      result = H.rarity_filter(MapSet.new(["rare", "mythic"]))
      assert is_list(result)
      assert "rare" in result
      assert "mythic" in result
    end
  end

  describe "parse_mana_value/1" do
    test "parses integer strings" do
      assert H.parse_mana_value("0") == 0
      assert H.parse_mana_value("3") == 3
      assert H.parse_mana_value("6") == 6
    end

    test "parses seven_plus to atom" do
      assert H.parse_mana_value("seven_plus") == :seven_plus
    end
  end

  describe "format_bytes/1" do
    test "formats bytes" do
      assert H.format_bytes(512) == "512 B"
    end

    test "formats kilobytes" do
      assert H.format_bytes(2048) == "2.0 KB"
    end

    test "formats megabytes" do
      assert H.format_bytes(4_400_000) =~ "MB"
    end

    test "formats gigabytes" do
      assert H.format_bytes(2_000_000_000) =~ "GB"
    end
  end

  describe "format_count/1" do
    test "formats small numbers without separator" do
      assert H.format_count(42) == "42"
    end

    test "formats thousands with comma" do
      assert H.format_count(92_411) == "92,411"
    end

    test "formats millions with commas" do
      assert H.format_count(1_234_567) == "1,234,567"
    end
  end

  describe "oban_status_class/1" do
    test "returns warning class when running" do
      assert H.oban_status_class(true) == "bg-warning"
    end

    test "returns success class when idle" do
      assert H.oban_status_class(false) == "bg-success"
    end
  end
end
