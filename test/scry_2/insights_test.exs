defmodule Scry2.InsightsTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights
  alias Scry2.Insights.Insight
  alias Scry2.Repo

  defp insert_insight!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          detector: "OnPlayVsOnDraw",
          surface: "home",
          tier: 1,
          title_template: "on_play_vs_on_draw.title",
          stats: %{"primary" => %{"num" => "60%", "lbl" => "play"}},
          measurements: %{"on_play_wr" => 0.60, "on_draw_wr" => 0.41},
          sample_size: 174,
          confidence: 0.04,
          computed_at: DateTime.utc_now()
        },
        overrides
      )

    %Insight{}
    |> Insight.changeset(attrs)
    |> Repo.insert!()
  end

  describe "list_active/1" do
    test "returns active insights for a surface, newest first" do
      _older = insert_insight!(%{computed_at: DateTime.add(DateTime.utc_now(), -3600, :second)})
      newer = insert_insight!(%{computed_at: DateTime.utc_now()})

      [first, _] = Insights.list_active(:home)
      assert first.id == newer.id
    end

    test "excludes superseded insights" do
      _superseded =
        insert_insight!(%{superseded_at: DateTime.utc_now()})

      active = insert_insight!(%{detector: "EventROI"})

      [only] = Insights.list_active(:home)
      assert only.id == active.id
    end

    test "excludes insights from other surfaces" do
      insert_insight!(%{surface: "insights_browser"})
      assert Insights.list_active(:home) == []
    end
  end

  describe "get/1 and get!/1" do
    test "fetches by id" do
      i = insert_insight!()
      assert Insights.get(i.id).id == i.id
      assert Insights.get!(i.id).id == i.id
    end

    test "get/1 returns nil for missing" do
      assert Insights.get(999_999) == nil
    end

    test "get!/1 raises for missing" do
      assert_raise Ecto.NoResultsError, fn -> Insights.get!(999_999) end
    end
  end

  describe "mark_shown!/1" do
    test "stamps last_shown_at and increments shown_count" do
      i = insert_insight!()
      assert i.shown_count == 0
      assert is_nil(i.last_shown_at)

      updated = Insights.mark_shown!(i)
      assert updated.shown_count == 1
      refute is_nil(updated.last_shown_at)
    end
  end

  describe "count/0" do
    test "returns the row count" do
      assert Insights.count() == 0
      insert_insight!()
      insert_insight!(%{detector: "EventROI"})
      assert Insights.count() == 2
    end
  end
end
