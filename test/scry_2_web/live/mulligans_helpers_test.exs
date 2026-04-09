defmodule Scry2Web.MulligansHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2.Mulligans.MulliganListing
  alias Scry2Web.MulligansHelpers

  describe "annotate_decisions/1" do
    test "single offer is kept" do
      row = %{build_listing(7, ~U[2026-04-05 12:00:00Z]) | decision: "kept"}

      assert [{hand, :kept}] = MulligansHelpers.annotate_decisions([row])
      assert hand.hand_size == 7
    end

    test "two offers — first mulliganed, second kept" do
      first = %{build_listing(7, ~U[2026-04-05 12:00:00Z]) | decision: "mulliganed"}
      second = %{build_listing(6, ~U[2026-04-05 12:00:01Z]) | decision: "kept"}

      result = MulligansHelpers.annotate_decisions([first, second])

      assert [{_, :mulliganed}, {_, :kept}] = result
    end

    test "three offers — first two mulliganed, last kept" do
      first = %{build_listing(7, ~U[2026-04-05 12:00:00Z]) | decision: "mulliganed"}
      second = %{build_listing(6, ~U[2026-04-05 12:00:01Z]) | decision: "mulliganed"}
      third = %{build_listing(5, ~U[2026-04-05 12:00:02Z]) | decision: "kept"}

      result = MulligansHelpers.annotate_decisions([third, first, second])

      assert [{_, :mulliganed}, {_, :mulliganed}, {_, :kept}] = result
    end

    test "empty list returns empty" do
      assert [] = MulligansHelpers.annotate_decisions([])
    end
  end

  describe "group_for_display/1" do
    test "groups by event, then by game, with correct sort order" do
      # Match A: older game in event X
      match_a = build_listing(7, ~U[2026-04-05 12:00:00Z], "match-a", "QuickDraft_FDN_20260323")

      # Match B: newer game in event X
      match_b = build_listing(7, ~U[2026-04-05 13:00:00Z], "match-b", "QuickDraft_FDN_20260323")

      result = MulligansHelpers.group_for_display([match_b, match_a])

      assert [%{event_name: "Quick Draft — FDN", games: games}] = result
      # Games sorted ascending (oldest first)
      assert [%{match_id: "match-a"}, %{match_id: "match-b"}] = games
    end

    test "events sorted newest-first" do
      old_event =
        build_listing(7, ~U[2026-04-01 12:00:00Z], "match-old", "QuickDraft_LCI_20260301")

      new_event =
        build_listing(7, ~U[2026-04-05 12:00:00Z], "match-new", "QuickDraft_FDN_20260323")

      result = MulligansHelpers.group_for_display([old_event, new_event])

      assert [%{event_name: "Quick Draft — FDN"}, %{event_name: "Quick Draft — LCI"}] = result
    end
  end

  describe "decision_label/1" do
    test "returns present-tense labels" do
      assert MulligansHelpers.decision_label(:kept) == "Keep"
      assert MulligansHelpers.decision_label(:mulliganed) == "Mulligan"
    end
  end

  describe "decision_badge_class/1" do
    test "returns badge classes" do
      assert MulligansHelpers.decision_badge_class(:kept) == "bg-orange-500/90 text-white"
      assert MulligansHelpers.decision_badge_class(:mulliganed) == "bg-blue-500/90 text-white"
    end
  end

  describe "format_event_name/1" do
    test "formats draft event names" do
      assert MulligansHelpers.format_event_name("QuickDraft_FDN_20260323") == "Quick Draft — FDN"

      assert MulligansHelpers.format_event_name("PremierDraft_LCI_20260401") ==
               "Premier Draft — LCI"
    end

    test "returns unknown formats as-is" do
      assert MulligansHelpers.format_event_name("Ladder") == "Ladder"
    end
  end

  defp build_listing(hand_size, occurred_at, match_id \\ "test-match", event_name \\ nil) do
    %MulliganListing{
      mtga_match_id: match_id,
      event_name: event_name,
      seat_id: 1,
      hand_size: hand_size,
      hand_arena_ids: %{"cards" => Enum.map(1..hand_size, fn _ -> Enum.random(10000..99999) end)},
      occurred_at: occurred_at
    }
  end
end
