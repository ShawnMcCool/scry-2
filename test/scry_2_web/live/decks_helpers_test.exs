defmodule Scry2Web.DecksHelpersTest do
  use ExUnit.Case, async: true

  doctest Scry2Web.DecksHelpers

  alias Scry2Web.DecksHelpers

  describe "deck_colors/1" do
    test "returns the deck_colors string" do
      assert DecksHelpers.deck_colors(%{deck_colors: "WUB"}) == "WUB"
    end

    test "returns empty string when deck_colors is nil" do
      assert DecksHelpers.deck_colors(%{deck_colors: nil}) == ""
    end

    test "returns empty string for unknown shape" do
      assert DecksHelpers.deck_colors(%{}) == ""
    end
  end

  describe "format_win_rate/1" do
    test "formats a float as percentage" do
      assert DecksHelpers.format_win_rate(55.3) == "55.3%"
      assert DecksHelpers.format_win_rate(100.0) == "100%"
      assert DecksHelpers.format_win_rate(0.0) == "0%"
      assert DecksHelpers.format_win_rate(50.0) == "50%"
    end

    test "returns em dash for nil" do
      assert DecksHelpers.format_win_rate(nil) == "—"
    end
  end

  describe "win_rate_class/1" do
    test "returns success class for >= 55%" do
      assert DecksHelpers.win_rate_class(55.0) == "text-emerald-400"
      assert DecksHelpers.win_rate_class(70.0) == "text-emerald-400"
    end

    test "returns neutral class for 45-54.9%" do
      assert DecksHelpers.win_rate_class(50.0) == "text-base-content"
      assert DecksHelpers.win_rate_class(45.0) == "text-base-content"
    end

    test "returns error class for < 45%" do
      assert DecksHelpers.win_rate_class(44.9) == "text-red-400"
      assert DecksHelpers.win_rate_class(0.0) == "text-red-400"
    end

    test "returns muted class for nil" do
      assert DecksHelpers.win_rate_class(nil) == "text-base-content/40"
    end
  end

  describe "record_str/2" do
    test "returns W–L string" do
      assert DecksHelpers.record_str(3, 2) == "3W–2L"
    end

    test "returns empty string when either arg is nil" do
      assert DecksHelpers.record_str(nil, 2) == ""
      assert DecksHelpers.record_str(3, nil) == ""
    end
  end

  describe "cumulative_winrate_series/1" do
    test "encodes cumulative data points as [timestamp, rate, record]" do
      points = [
        %{timestamp: "2026-04-09T20:38:35Z", win_rate: 100.0, wins: 1, total: 1},
        %{timestamp: "2026-04-12T11:17:46Z", win_rate: 100.0, wins: 2, total: 2},
        %{timestamp: "2026-04-12T12:02:16Z", win_rate: 66.7, wins: 2, total: 3}
      ]

      decoded = DecksHelpers.cumulative_winrate_series(points) |> Jason.decode!()

      assert decoded == [
               ["2026-04-09T20:38:35Z", 100.0, "1W–0L"],
               ["2026-04-12T11:17:46Z", 100.0, "2W–0L"],
               ["2026-04-12T12:02:16Z", 66.7, "2W–1L"]
             ]
    end

    test "returns empty array for no data" do
      assert DecksHelpers.cumulative_winrate_series([]) |> Jason.decode!() == []
    end
  end

  describe "format_date/1" do
    test "formats a datetime as YYYY-MM-DD" do
      dt = ~U[2026-04-09 10:30:00Z]
      assert DecksHelpers.format_date(dt) == "2026-04-09"
    end

    test "returns em dash for nil" do
      assert DecksHelpers.format_date(nil) == "—"
    end
  end

  describe "group_matches_by_date/1" do
    test "returns empty list for empty input" do
      assert DecksHelpers.group_matches_by_date([]) == []
    end

    test "groups today's matches under Today" do
      today_dt = DateTime.utc_now()
      match = %{started_at: today_dt, id: 1}

      groups = DecksHelpers.group_matches_by_date([match])

      assert [{"Today", [^match]}] = groups
    end

    test "groups yesterday's matches under Yesterday" do
      yesterday_dt = DateTime.add(DateTime.utc_now(), -86_400, :second)
      match = %{started_at: yesterday_dt, id: 1}

      groups = DecksHelpers.group_matches_by_date([match])

      assert [{"Yesterday", [^match]}] = groups
    end

    test "groups older matches under formatted date label" do
      dt = ~U[2026-04-10 15:00:00Z]
      match = %{started_at: dt, id: 1}

      groups = DecksHelpers.group_matches_by_date([match])

      assert [{"April 10", [^match]}] = groups
    end

    test "groups match with nil started_at under Unknown" do
      match = %{started_at: nil, id: 1}

      groups = DecksHelpers.group_matches_by_date([match])

      assert [{"Unknown", [^match]}] = groups
    end

    test "groups multiple matches by date, newest group first" do
      dt_older = ~U[2026-04-08 10:00:00Z]
      dt_newer = ~U[2026-04-10 10:00:00Z]
      match_older = %{started_at: dt_older, id: 1}
      match_newer = %{started_at: dt_newer, id: 2}

      groups = DecksHelpers.group_matches_by_date([match_newer, match_older])

      labels = Enum.map(groups, fn {label, _} -> label end)
      assert "April 10" in labels
      assert "April 8" in labels

      assert Enum.find_index(labels, &(&1 == "April 10")) <
               Enum.find_index(labels, &(&1 == "April 8"))
    end
  end

  describe "humanize_event/2" do
    test "returns em dash for nil event name" do
      assert DecksHelpers.humanize_event(nil, "Standard") == "—"
    end

    test "Traditional_Ladder with Standard deck format -> Ranked Standard" do
      assert DecksHelpers.humanize_event("Traditional_Ladder_Standard", "Standard") ==
               "Ranked Standard"
    end

    test "Ladder with Standard deck format -> Ranked Standard" do
      assert DecksHelpers.humanize_event("Ladder_Standard_2026", "Standard") == "Ranked Standard"
    end

    test "DirectGame -> Direct Challenge regardless of deck format" do
      assert DecksHelpers.humanize_event("DirectGame", "Standard") == "Direct Challenge"
      assert DecksHelpers.humanize_event("DirectGame", nil) == "Direct Challenge"
    end

    test "QuickDraft -> Quick Draft (limited, ignores deck format)" do
      assert DecksHelpers.humanize_event("QuickDraft_WOE", nil) == "Quick Draft"
    end

    test "PremierDraft -> Premier Draft" do
      assert DecksHelpers.humanize_event("PremierDraft_WOE", nil) == "Premier Draft"
    end

    test "Play with Standard deck format -> Play Standard" do
      assert DecksHelpers.humanize_event("Play_Standard", "Standard") == "Play Standard"
    end

    test "Traditional_Play with Standard deck format -> Play BO3 Standard" do
      assert DecksHelpers.humanize_event("Traditional_Play_Standard", "Standard") ==
               "Play BO3 Standard"
    end

    test "uses fallback when deck_format is nil for constructed events" do
      assert DecksHelpers.humanize_event("Ladder_Standard", nil) == "Ranked Constructed"
    end
  end

  describe "format_game_results/1" do
    test "returns empty list for nil" do
      assert DecksHelpers.format_game_results(nil) == []
    end

    test "returns empty list for unrecognized shape" do
      assert DecksHelpers.format_game_results(%{}) == []
    end

    test "extracts per-game details sorted by game number" do
      game_results = %{
        "results" => [
          %{"game" => 2, "won" => false, "on_play" => false, "num_mulligans" => 1},
          %{"game" => 1, "won" => true, "on_play" => true, "num_mulligans" => 0}
        ]
      }

      result = DecksHelpers.format_game_results(game_results)

      assert result == [
               %{won: true, on_play: true, num_mulligans: 0},
               %{won: false, on_play: false, num_mulligans: 1}
             ]
    end

    test "defaults num_mulligans to 0 when missing" do
      game_results = %{
        "results" => [
          %{"game" => 1, "won" => true, "on_play" => true}
        ]
      }

      [game] = DecksHelpers.format_game_results(game_results)
      assert game.num_mulligans == 0
    end
  end

  describe "deck_result_line/1" do
    alias Scry2.Decks.Deck

    test "trophy run for a 7-win draft deck" do
      deck = %Deck{
        mtga_deck_id: "draft:QuickDraft_SOS_20260430",
        bo1_wins: 7,
        bo1_losses: 2,
        bo3_wins: 0,
        bo3_losses: 0
      }

      assert DecksHelpers.deck_result_line(deck) == "Trophy run — 7-2"
    end

    test "plain finished record for a sub-trophy run" do
      deck = %Deck{
        mtga_deck_id: "draft:QuickDraft_SOS_20260430",
        bo1_wins: 3,
        bo1_losses: 4,
        bo3_wins: 0,
        bo3_losses: 0
      }

      assert DecksHelpers.deck_result_line(deck) == "Finished 3-4"
    end

    test "no trophy framing for a constructed deck even at 7+ wins" do
      deck = %Deck{
        mtga_deck_id: "real-deck-1",
        bo1_wins: 12,
        bo1_losses: 4,
        bo3_wins: 0,
        bo3_losses: 0
      }

      assert DecksHelpers.deck_result_line(deck) == "Finished 12-4"
    end

    test "combines bo1 and bo3 counts" do
      deck = %Deck{
        mtga_deck_id: "real-deck-1",
        bo1_wins: 2,
        bo1_losses: 1,
        bo3_wins: 3,
        bo3_losses: 2
      }

      assert DecksHelpers.deck_result_line(deck) == "Finished 5-3"
    end

    test "no matches yet" do
      deck = %Deck{
        mtga_deck_id: "draft:x",
        bo1_wins: 0,
        bo1_losses: 0,
        bo3_wins: 0,
        bo3_losses: 0
      }

      assert DecksHelpers.deck_result_line(deck) == "No matches recorded yet"
    end
  end

  describe "match_score/1" do
    test "returns nil for nil input" do
      assert DecksHelpers.match_score(nil) == nil
    end

    test "returns nil for single-game match (BO1)" do
      assert DecksHelpers.match_score(%{won: true, num_games: 1}) == nil
    end

    test "returns 2-1 for a 3-game win" do
      assert DecksHelpers.match_score(%{won: true, num_games: 3}) == "2–1"
    end

    test "returns 2-0 for a 2-game win" do
      assert DecksHelpers.match_score(%{won: true, num_games: 2}) == "2–0"
    end

    test "returns 1-2 for a 3-game loss" do
      assert DecksHelpers.match_score(%{won: false, num_games: 3}) == "1–2"
    end

    test "returns 0-2 for a 2-game loss" do
      assert DecksHelpers.match_score(%{won: false, num_games: 2}) == "0–2"
    end

    test "returns nil for missing data" do
      assert DecksHelpers.match_score(%{}) == nil
    end
  end
end
