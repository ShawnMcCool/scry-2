defmodule Scry2.Insights.Detectors.RankMilestoneTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.RankMilestone
  alias Scry2.Insights.Insight
  alias Scry2.Ranks.Snapshot
  alias Scry2.Repo

  # The detector treats Bronze as the starting floor — only promotions to
  # Silver and above count as milestones.
  defp insert_snapshot!(attrs) do
    defaults = %{
      season_ordinal: 100,
      occurred_at: DateTime.utc_now(:second)
    }

    %Snapshot{}
    |> Snapshot.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp days_ago(n) do
    DateTime.utc_now(:second) |> DateTime.add(-n, :day)
  end

  describe "tier/0" do
    test "is tier 1" do
      assert RankMilestone.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil when there are no snapshots" do
      assert RankMilestone.detect([]) == nil
    end

    test "returns nil when the player has never climbed above Bronze" do
      insert_snapshot!(%{constructed_class: "Bronze", occurred_at: days_ago(2)})
      insert_snapshot!(%{constructed_class: "Bronze", occurred_at: days_ago(1)})
      assert RankMilestone.detect([]) == nil
    end

    test "returns nil when the most recent promotion is outside the lookback window" do
      insert_snapshot!(%{constructed_class: "Bronze", occurred_at: days_ago(60)})
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(50)})
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(40)})
      assert RankMilestone.detect([]) == nil
    end

    test "returns insight when player promoted into a new class within the lookback window" do
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(10)})
      insert_snapshot!(%{constructed_class: "Gold", occurred_at: days_ago(3)})

      assert %Insight{} = insight = RankMilestone.detect([])
      assert insight.detector == "RankMilestone"
      assert insight.tier == 1
      assert insight.measurements["class"] == "Gold"
      assert insight.measurements["format"] == "constructed"
      assert insight.measurements["days_ago"] == 3
    end

    test "uses the first-time-reached snapshot when the player decays and re-reaches the class" do
      # First reached Gold 10 days ago, decayed to Silver, re-reached Gold 2 days ago.
      # The milestone should reflect the original promotion (10 days ago), not the re-climb.
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(15)})
      insert_snapshot!(%{constructed_class: "Gold", occurred_at: days_ago(10)})
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(5)})
      insert_snapshot!(%{constructed_class: "Gold", occurred_at: days_ago(2)})

      assert %Insight{} = insight = RankMilestone.detect([])
      assert insight.measurements["class"] == "Gold"
      assert insight.measurements["days_ago"] == 10
    end

    test "prefers the higher class when both formats have a recent milestone" do
      # Limited: Gold reached 2 days ago.
      # Constructed: Diamond reached 8 days ago.
      # Diamond > Gold → constructed Diamond wins despite being older.
      insert_snapshot!(%{
        constructed_class: "Platinum",
        limited_class: "Silver",
        occurred_at: days_ago(12)
      })

      insert_snapshot!(%{
        constructed_class: "Diamond",
        limited_class: "Silver",
        occurred_at: days_ago(8)
      })

      insert_snapshot!(%{
        constructed_class: "Diamond",
        limited_class: "Gold",
        occurred_at: days_ago(2)
      })

      assert %Insight{} = insight = RankMilestone.detect([])
      assert insight.measurements["class"] == "Diamond"
      assert insight.measurements["format"] == "constructed"
    end

    test "counts how many class promotions occurred in the season" do
      insert_snapshot!(%{constructed_class: "Bronze", occurred_at: days_ago(20)})
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(15)})
      insert_snapshot!(%{constructed_class: "Gold", occurred_at: days_ago(10)})
      insert_snapshot!(%{constructed_class: "Platinum", occurred_at: days_ago(2)})

      assert %Insight{} = insight = RankMilestone.detect([])
      assert insight.measurements["class"] == "Platinum"
      assert insight.measurements["promotions_this_season"] == 3
    end

    test "fills stats payload for tile rendering" do
      insert_snapshot!(%{constructed_class: "Silver", occurred_at: days_ago(5)})
      insert_snapshot!(%{constructed_class: "Gold", occurred_at: days_ago(1)})

      assert %Insight{stats: stats} = RankMilestone.detect([])
      assert stats["primary"]["num"] == "Gold"
      assert stats["primary"]["lbl"] == "rank reached"
      assert stats["secondary"]["num"] =~ ~r/\d+d ago/
      assert stats["tertiary"]["num"] == "constructed"
    end
  end
end
