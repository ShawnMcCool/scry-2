defmodule Scry2.Showcase.TileSpecTest do
  use ExUnit.Case, async: true

  alias Scry2.Showcase.TileSpec

  describe "%TileSpec{}" do
    test "valid construction with required keys only" do
      spec = %TileSpec{
        kind: :latest_match,
        composition: :activity,
        title: "WIN 2-1",
        target: {:navigate, "/matches/1"}
      }

      assert spec.kind == :latest_match
      assert spec.composition == :activity
      assert spec.body == nil
      assert spec.stats == nil
      assert spec.meta == []
      assert spec.badge == nil
    end

    test "raises if any enforced key is missing" do
      assert_raise ArgumentError, fn ->
        struct!(TileSpec, %{kind: :foo})
      end
    end

    test "accepts the insight composition" do
      spec = %TileSpec{
        kind: :coach_insight,
        composition: :insight,
        title: "Pattern noticed",
        body: "Body text",
        stats: [%{"num" => "60%", "lbl" => "play"}],
        meta: ["n=174"],
        target: {:navigate, "/insights/1"},
        badge: :tier_2
      }

      assert spec.composition == :insight
      assert length(spec.stats) == 1
      assert spec.badge == :tier_2
    end
  end
end
