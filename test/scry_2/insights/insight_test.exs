defmodule Scry2.Insights.InsightTest do
  use ExUnit.Case, async: true

  alias Scry2.Insights.Insight

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        detector: "OnPlayVsOnDraw",
        surface: "home",
        tier: 1,
        title_template: "on_play_vs_on_draw.title",
        body_template: "on_play_vs_on_draw.body",
        stats: %{"primary" => %{"num" => "60%", "lbl" => "play"}},
        measurements: %{"on_play_wr" => 0.60, "on_draw_wr" => 0.41},
        sample_size: 174,
        confidence: 0.04,
        computed_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "valid attrs → valid changeset" do
      changeset = Insight.changeset(%Insight{}, valid_attrs())
      assert changeset.valid?
    end

    test "missing required fields → invalid" do
      changeset = Insight.changeset(%Insight{}, %{})
      refute changeset.valid?

      errors = Keyword.keys(changeset.errors)
      assert :detector in errors
      assert :surface in errors
      assert :tier in errors
      assert :title_template in errors
      assert :sample_size in errors
      assert :computed_at in errors
    end

    test "tier outside [1, 2] → invalid" do
      changeset = Insight.changeset(%Insight{}, valid_attrs(%{tier: 3}))
      refute changeset.valid?
      assert {_msg, _opts} = changeset.errors[:tier]
    end

    test "surface must be a known value" do
      changeset = Insight.changeset(%Insight{}, valid_attrs(%{surface: "bogus"}))
      refute changeset.valid?
      assert {_msg, _opts} = changeset.errors[:surface]
    end

    test "negative sample_size → invalid" do
      changeset = Insight.changeset(%Insight{}, valid_attrs(%{sample_size: -1}))
      refute changeset.valid?
      assert {_msg, _opts} = changeset.errors[:sample_size]
    end

    test "body_template is optional" do
      changeset = Insight.changeset(%Insight{}, valid_attrs(%{body_template: nil}))
      assert changeset.valid?
    end
  end
end
