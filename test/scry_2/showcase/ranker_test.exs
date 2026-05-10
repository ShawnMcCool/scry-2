defmodule Scry2.Showcase.RankerTest do
  use ExUnit.Case, async: true

  alias Scry2.Insights.Insight
  alias Scry2.Showcase.Ranker

  defp build(attrs) do
    defaults = %Insight{
      detector: "Test",
      surface: "home",
      tier: 1,
      title_template: "test.title",
      sample_size: 50,
      confidence: nil,
      computed_at: DateTime.utc_now(),
      shown_count: 0
    }

    struct(defaults, attrs)
  end

  describe "score/2" do
    test "is non-negative" do
      assert Ranker.score(build(%{})) >= 0.0
    end

    test "larger sample → higher score, all else equal" do
      now = DateTime.utc_now()
      small = Ranker.score(build(%{sample_size: 30}), now)
      large = Ranker.score(build(%{sample_size: 200}), now)
      assert large > small
    end

    test "Tier-2 with significant p-value scores higher than Tier-1 of same n" do
      now = DateTime.utc_now()
      tier_1 = Ranker.score(build(%{tier: 1, sample_size: 100, confidence: nil}), now)
      tier_2 = Ranker.score(build(%{tier: 2, sample_size: 100, confidence: 0.01}), now)
      assert tier_2 > tier_1
    end

    test "high shown_count → lower score (decays with familiarity)" do
      now = DateTime.utc_now()
      fresh = Ranker.score(build(%{shown_count: 0}), now)
      seen = Ranker.score(build(%{shown_count: 10}), now)
      assert fresh > seen
    end

    test "older computed_at → lower score" do
      now = DateTime.utc_now()
      today = Ranker.score(build(%{computed_at: now}), now)
      old = Ranker.score(build(%{computed_at: DateTime.add(now, -10, :day)}), now)
      assert today > old
    end

    test "computed_at = nil → score is 0" do
      assert Ranker.score(build(%{computed_at: nil})) == 0.0
    end
  end
end
