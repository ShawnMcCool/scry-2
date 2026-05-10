defmodule Scry2.Showcase.HomepageTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights
  alias Scry2.Showcase.{Homepage, TileSpec}
  alias Scry2.TestFactory

  describe "tiles/1 — activity mode" do
    test "returns empty list when nothing exists" do
      assert Homepage.tiles() == []
    end

    test "returns the latest_match tile when matches exist but no insights" do
      _match = TestFactory.create_match(%{won: true, on_play: true})

      tiles = Homepage.tiles()

      assert [%TileSpec{kind: :latest_match, composition: :activity}] = tiles
    end
  end

  describe "tiles/1 — pattern mode" do
    setup do
      # Seed enough matches for OnPlayVsOnDraw to fire.
      for _ <- 1..30 do
        TestFactory.create_match(%{on_play: true, won: true})
      end

      {:ok, _} = Insights.compute_all()
      :ok
    end

    test "returns latest_match + coach_insight tiles when active insights exist" do
      tiles = Homepage.tiles()

      kinds = Enum.map(tiles, & &1.kind)
      compositions = Enum.map(tiles, & &1.composition)

      assert :latest_match in kinds
      assert :coach_insight in kinds
      assert :activity in compositions
      assert :insight in compositions
    end

    test "respects the four-tile cap" do
      assert length(Homepage.tiles()) <= 4
    end

    test "coach tiles point to /insights/:id" do
      tiles = Homepage.tiles()
      coach = Enum.find(tiles, &(&1.kind == :coach_insight))

      assert {:navigate, "/insights/" <> _} = coach.target
    end

    test "latest_match tile points to /matches/:id" do
      tiles = Homepage.tiles()
      latest = Enum.find(tiles, &(&1.kind == :latest_match))

      assert {:navigate, "/matches/" <> _} = latest.target
    end
  end
end
