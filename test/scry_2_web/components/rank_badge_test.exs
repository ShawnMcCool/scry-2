defmodule Scry2Web.Components.RankBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Scry2Web.Components.RankBadge

  describe "rank_badge/1" do
    test "renders 'Unranked' fallback when rank is nil" do
      html = render_component(&rank_badge/1, rank: nil)
      assert html =~ "Unranked"
    end

    test "renders bare rank string when no mythic data" do
      html = render_component(&rank_badge/1, rank: "Gold 3")
      assert html =~ "Gold 3"
    end

    test "renders Mythic placement when positive" do
      html =
        render_component(&rank_badge/1,
          rank: "Mythic",
          mythic_placement: 142
        )

      assert html =~ "Mythic"
      assert html =~ "#142"
    end

    test "renders Mythic percentile when positive and no placement" do
      html =
        render_component(&rank_badge/1,
          rank: "Mythic",
          mythic_percentile: 88
        )

      assert html =~ "Mythic"
      assert html =~ "88%"
    end

    test "treats placement of 0 as absent" do
      html =
        render_component(&rank_badge/1,
          rank: "Mythic",
          mythic_placement: 0,
          mythic_percentile: 88
        )

      assert html =~ "88%"
      refute html =~ "#0"
    end

    test "renders bare 'Mythic' when both mythic fields are nil/0" do
      html =
        render_component(&rank_badge/1,
          rank: "Mythic",
          mythic_placement: 0,
          mythic_percentile: 0
        )

      assert html =~ "Mythic"
      refute html =~ "#"
      refute html =~ "%"
    end

    test "placement wins over percentile when both positive" do
      html =
        render_component(&rank_badge/1,
          rank: "Mythic",
          mythic_placement: 142,
          mythic_percentile: 88
        )

      assert html =~ "#142"
      refute html =~ "88%"
    end
  end
end
