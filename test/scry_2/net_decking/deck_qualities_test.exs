defmodule Scry2.NetDecking.DeckQualitiesTest do
  use ExUnit.Case, async: true
  alias Scry2.NetDecking.DeckQualities

  describe "color_combo_name/1" do
    test "names mono, guild, shard/wedge, 4c, 5c, colorless" do
      assert DeckQualities.color_combo_name("") == "Colorless"
      assert DeckQualities.color_combo_name("R") == "Mono-Red"
      assert DeckQualities.color_combo_name("WR") == "Boros"
      assert DeckQualities.color_combo_name("UR") == "Izzet"
      assert DeckQualities.color_combo_name("WUR") == "Jeskai"
      assert DeckQualities.color_combo_name("BRG") == "Jund"
      assert DeckQualities.color_combo_name("WUBR") == "4-color"
      assert DeckQualities.color_combo_name("WUBRG") == "5-color"
    end
  end
end
