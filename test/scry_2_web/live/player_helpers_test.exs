defmodule Scry2Web.PlayerHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.PlayerHelpers

  describe "format_win_rate/1" do
    test "formats a percentage" do
      assert PlayerHelpers.format_win_rate(55.3) == "55.3%"
    end

    test "returns dash for nil" do
      assert PlayerHelpers.format_win_rate(nil) == "—"
    end
  end

  describe "win_rate_class/1" do
    test "green above 50" do
      assert PlayerHelpers.win_rate_class(55.0) =~ "emerald"
    end

    test "red below 50" do
      assert PlayerHelpers.win_rate_class(45.0) =~ "red"
    end

    test "neutral at 50" do
      assert PlayerHelpers.win_rate_class(50.0) == "text-base-content"
    end

    test "muted for nil" do
      assert PlayerHelpers.win_rate_class(nil) =~ "50"
    end
  end

  describe "format_avg/1" do
    test "formats a float to one decimal" do
      assert PlayerHelpers.format_avg(7.333) == "7.3"
    end

    test "returns dash for nil" do
      assert PlayerHelpers.format_avg(nil) == "—"
    end
  end

  describe "record/2" do
    test "formats a W-L record" do
      assert PlayerHelpers.record(10, 5) == "10–5"
    end
  end

  describe "format_streak/1" do
    test "formats a win streak" do
      assert PlayerHelpers.format_streak({:win, 4}) == "W4"
    end

    test "formats a loss streak" do
      assert PlayerHelpers.format_streak({:loss, 2}) == "L2"
    end

    test "returns dash for no streak" do
      assert PlayerHelpers.format_streak({:none, 0}) == "—"
    end
  end

  describe "streak_class/1" do
    test "green for win streak" do
      assert PlayerHelpers.streak_class({:win, 3}) =~ "emerald"
    end

    test "red for loss streak" do
      assert PlayerHelpers.streak_class({:loss, 2}) =~ "red"
    end

    test "muted for no streak" do
      assert PlayerHelpers.streak_class({:none, 0}) =~ "50"
    end
  end

  describe "top_decks/3" do
    test "returns top decks sorted by combined win rate" do
      decks = [
        %{
          deck: %{current_name: "Aggro", mtga_deck_id: "d1", deck_colors: "R"},
          bo1: %{total: 10, wins: 6, losses: 4},
          bo3: %{total: 0, wins: 0, losses: 0}
        },
        %{
          deck: %{current_name: "Control", mtga_deck_id: "d2", deck_colors: "WU"},
          bo1: %{total: 5, wins: 4, losses: 1},
          bo3: %{total: 5, wins: 3, losses: 2}
        },
        %{
          deck: %{current_name: "Midrange", mtga_deck_id: "d3", deck_colors: "BG"},
          bo1: %{total: 20, wins: 12, losses: 8},
          bo3: %{total: 0, wins: 0, losses: 0}
        }
      ]

      result = PlayerHelpers.top_decks(decks, 2)

      assert length(result) == 2
      assert hd(result).name == "Control"
      assert hd(result).win_rate == 70.0
    end

    test "excludes decks below minimum match count" do
      decks = [
        %{
          deck: %{current_name: "One-off", mtga_deck_id: "d1", deck_colors: "W"},
          bo1: %{total: 1, wins: 1, losses: 0},
          bo3: %{total: 0, wins: 0, losses: 0}
        },
        %{
          deck: %{current_name: "Regular", mtga_deck_id: "d2", deck_colors: "U"},
          bo1: %{total: 5, wins: 3, losses: 2},
          bo3: %{total: 0, wins: 0, losses: 0}
        }
      ]

      result = PlayerHelpers.top_decks(decks)

      assert length(result) == 1
      assert hd(result).name == "Regular"
    end
  end
end
