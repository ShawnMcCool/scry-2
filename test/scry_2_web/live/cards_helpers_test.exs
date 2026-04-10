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

  describe "params_from_filters/5" do
    test "returns empty map when all filters are default" do
      assert H.params_from_filters("", MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new()) ==
               %{}
    end

    test "encodes search text under q" do
      result =
        H.params_from_filters("bolt", MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new())

      assert result["q"] == "bolt"
    end

    test "encodes colors as sorted comma-separated string" do
      result =
        H.params_from_filters(
          "",
          MapSet.new(["R", "U"]),
          MapSet.new(),
          MapSet.new(),
          MapSet.new()
        )

      assert result["colors"] == "R,U"
    end

    test "encodes rarities under r" do
      result =
        H.params_from_filters(
          "",
          MapSet.new(),
          MapSet.new(["rare", "mythic"]),
          MapSet.new(),
          MapSet.new()
        )

      colors = String.split(result["r"], ",")
      assert "rare" in colors
      assert "mythic" in colors
    end

    test "encodes mana values under mv, seven_plus as 7+" do
      result =
        H.params_from_filters(
          "",
          MapSet.new(),
          MapSet.new(),
          MapSet.new([2, :seven_plus]),
          MapSet.new()
        )

      parts = String.split(result["mv"], ",")
      assert "2" in parts
      assert "7+" in parts
    end

    test "encodes types under t" do
      result =
        H.params_from_filters(
          "",
          MapSet.new(),
          MapSet.new(),
          MapSet.new(),
          MapSet.new([:creature, :instant])
        )

      parts = String.split(result["t"], ",")
      assert "creature" in parts
      assert "instant" in parts
    end

    test "omits empty filter keys" do
      result =
        H.params_from_filters("bolt", MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new())

      refute Map.has_key?(result, "colors")
      refute Map.has_key?(result, "r")
      refute Map.has_key?(result, "mv")
      refute Map.has_key?(result, "t")
    end
  end

  describe "decode_search/1" do
    test "returns empty string when q absent" do
      assert H.decode_search(%{}) == ""
    end

    test "returns the q value" do
      assert H.decode_search(%{"q" => "bolt"}) == "bolt"
    end
  end

  describe "decode_colors/1" do
    test "returns empty MapSet when colors absent" do
      assert H.decode_colors(%{}) == MapSet.new()
    end

    test "parses comma-separated colors" do
      assert H.decode_colors(%{"colors" => "W,R"}) == MapSet.new(["W", "R"])
    end

    test "ignores invalid color codes" do
      assert H.decode_colors(%{"colors" => "W,X,R"}) == MapSet.new(["W", "R"])
    end
  end

  describe "decode_rarities/1" do
    test "returns empty MapSet when r absent" do
      assert H.decode_rarities(%{}) == MapSet.new()
    end

    test "parses comma-separated rarities" do
      assert H.decode_rarities(%{"r" => "common,mythic"}) == MapSet.new(["common", "mythic"])
    end

    test "ignores invalid rarity values" do
      assert H.decode_rarities(%{"r" => "common,bogus"}) == MapSet.new(["common"])
    end
  end

  describe "decode_mana_values/1" do
    test "returns empty MapSet when mv absent" do
      assert H.decode_mana_values(%{}) == MapSet.new()
    end

    test "parses integer mana values" do
      assert H.decode_mana_values(%{"mv" => "2,4"}) == MapSet.new([2, 4])
    end

    test "parses 7+ as :seven_plus" do
      assert H.decode_mana_values(%{"mv" => "3,7+"}) == MapSet.new([3, :seven_plus])
    end
  end

  describe "decode_types/1" do
    test "returns empty MapSet when t absent" do
      assert H.decode_types(%{}) == MapSet.new()
    end

    test "parses comma-separated type strings to atoms" do
      assert H.decode_types(%{"t" => "creature,instant"}) == MapSet.new([:creature, :instant])
    end

    test "ignores invalid type values" do
      assert H.decode_types(%{"t" => "creature,bogus"}) == MapSet.new([:creature])
    end
  end
end
