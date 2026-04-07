defmodule Scry2Web.MulligansHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.MulliganOffered
  alias Scry2Web.MulligansHelpers

  describe "annotate_decisions/1" do
    test "single offer is kept" do
      offer = build_offer(7, ~U[2026-04-05 12:00:00Z])

      assert [{^offer, :kept}] = MulligansHelpers.annotate_decisions([offer])
    end

    test "two offers — first mulliganed, second kept" do
      first = build_offer(7, ~U[2026-04-05 12:00:00Z])
      second = build_offer(6, ~U[2026-04-05 12:00:01Z])

      result = MulligansHelpers.annotate_decisions([first, second])

      assert [{^first, :mulliganed}, {^second, :kept}] = result
    end

    test "three offers — first two mulliganed, last kept" do
      first = build_offer(7, ~U[2026-04-05 12:00:00Z])
      second = build_offer(6, ~U[2026-04-05 12:00:01Z])
      third = build_offer(5, ~U[2026-04-05 12:00:02Z])

      result = MulligansHelpers.annotate_decisions([third, first, second])

      assert [{^first, :mulliganed}, {^second, :mulliganed}, {^third, :kept}] = result
    end

    test "empty list returns empty" do
      assert [] = MulligansHelpers.annotate_decisions([])
    end
  end

  describe "group_by_match/1" do
    test "groups events by match_id and annotates decisions" do
      match_a_1 = build_offer(7, ~U[2026-04-05 12:00:00Z], "match-a")
      match_a_2 = build_offer(6, ~U[2026-04-05 12:00:01Z], "match-a")
      match_b_1 = build_offer(7, ~U[2026-04-05 13:00:00Z], "match-b")

      result = MulligansHelpers.group_by_match([match_a_1, match_b_1, match_a_2])

      assert [%{match_id: "match-b"}, %{match_id: "match-a"}] = result

      match_a = Enum.find(result, &(&1.match_id == "match-a"))
      assert [{_, :mulliganed}, {_, :kept}] = match_a.hands
    end
  end

  describe "decision_label/1" do
    test "returns human labels" do
      assert MulligansHelpers.decision_label(:kept) == "Kept"
      assert MulligansHelpers.decision_label(:mulliganed) == "Mulliganed"
    end
  end

  describe "decision_badge_class/1" do
    test "returns badge classes" do
      assert MulligansHelpers.decision_badge_class(:kept) == "badge-warning badge-outline"
      assert MulligansHelpers.decision_badge_class(:mulliganed) == "badge-info badge-outline"
    end
  end

  describe "decision_border_class/1" do
    test "returns border accent classes" do
      assert MulligansHelpers.decision_border_class(:kept) == "border-warning"
      assert MulligansHelpers.decision_border_class(:mulliganed) == "border-info"
    end
  end

  defp build_offer(hand_size, occurred_at, match_id \\ "test-match") do
    %MulliganOffered{
      mtga_match_id: match_id,
      seat_id: 1,
      hand_size: hand_size,
      hand_arena_ids: Enum.map(1..hand_size, fn _ -> Enum.random(10000..99999) end),
      occurred_at: occurred_at
    }
  end
end
