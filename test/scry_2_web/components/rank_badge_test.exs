defmodule Scry2Web.Components.RankBadgeTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Components.RankBadge

  describe "display_text/1" do
    test "returns 'Unranked' fallback when rank is nil" do
      assert RankBadge.display_text(%{rank: nil}) == "Unranked"
    end

    test "returns bare rank string when no mythic data" do
      assert RankBadge.display_text(%{rank: "Gold 3"}) == "Gold 3"
    end

    test "returns Mythic placement when positive" do
      assert RankBadge.display_text(%{
               rank: "Mythic",
               mythic_placement: 142,
               mythic_percentile: nil
             }) == "Mythic #142"
    end

    test "returns Mythic percentile when positive and no placement" do
      assert RankBadge.display_text(%{
               rank: "Mythic",
               mythic_placement: nil,
               mythic_percentile: 88
             }) == "Mythic 88%"
    end

    test "treats placement of 0 as absent" do
      assert RankBadge.display_text(%{
               rank: "Mythic",
               mythic_placement: 0,
               mythic_percentile: 88
             }) == "Mythic 88%"
    end

    test "returns bare 'Mythic' when both mythic fields are nil/0" do
      assert RankBadge.display_text(%{
               rank: "Mythic",
               mythic_placement: 0,
               mythic_percentile: 0
             }) == "Mythic"
    end

    test "placement wins over percentile when both positive" do
      assert RankBadge.display_text(%{
               rank: "Mythic",
               mythic_placement: 142,
               mythic_percentile: 88
             }) == "Mythic #142"
    end
  end
end
