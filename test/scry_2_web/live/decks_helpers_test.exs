defmodule Scry2Web.DecksHelpersTest do
  use ExUnit.Case, async: true

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
      assert DecksHelpers.format_win_rate(100.0) == "100.0%"
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

  describe "card_name/2" do
    test "returns card name when found" do
      cards = %{12345 => %{name: "Lightning Bolt"}}
      assert DecksHelpers.card_name(12345, cards) == "Lightning Bolt"
    end

    test "returns stringified arena_id when not found" do
      assert DecksHelpers.card_name(99999, %{}) == "99999"
    end

    test "returns Unknown for nil arena_id" do
      assert DecksHelpers.card_name(nil, %{}) == "Unknown"
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

  describe "group_deck_cards/2" do
    test "groups cards by type and sorts by mana value" do
      deck = %{
        current_main_deck: %{
          "cards" => [
            %{"arena_id" => 1, "count" => 4},
            %{"arena_id" => 2, "count" => 2}
          ]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Lightning Bolt", types: "Instant", mana_value: 1},
        2 => %{name: "Counterspell", types: "Instant", mana_value: 2}
      }

      groups = DecksHelpers.group_deck_cards(deck, cards_by_arena_id)
      {"Instants", cards} = List.first(groups)

      names = Enum.map(cards, & &1.name)
      assert "Lightning Bolt" in names
      assert "Counterspell" in names
      # Sorted by mana value: Lightning Bolt (1) before Counterspell (2)
      assert Enum.find_index(cards, &(&1.name == "Lightning Bolt")) <
               Enum.find_index(cards, &(&1.name == "Counterspell"))
    end

    test "returns empty list when deck has no cards" do
      deck = %{current_main_deck: %{"cards" => []}}
      assert DecksHelpers.group_deck_cards(deck, %{}) == []
    end
  end

  describe "mana_curve_series/2" do
    test "excludes lands from the mana curve" do
      deck = %{
        current_main_deck: %{
          "cards" => [
            %{"arena_id" => 1, "count" => 4},
            %{"arena_id" => 2, "count" => 24}
          ]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Lightning Bolt", types: "Instant", mana_value: 1},
        2 => %{name: "Mountain", types: "Basic Land", mana_value: 0}
      }

      decoded = deck |> DecksHelpers.mana_curve_series(cards_by_arena_id) |> Jason.decode!()

      # CMC 1 should have 4 (the bolts)
      assert Enum.find(decoded, fn [label, _] -> label == "1" end) == ["1", 4]
      # CMC 0 should be 0 — lands are excluded
      assert Enum.find(decoded, fn [label, _] -> label == "0" end) == ["0", 0]
    end

    test "counts non-land cards by mana value" do
      deck = %{
        current_main_deck: %{
          "cards" => [
            %{"arena_id" => 1, "count" => 4},
            %{"arena_id" => 2, "count" => 2}
          ]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Opt", types: "Instant", mana_value: 1},
        2 => %{name: "Counterspell", types: "Instant", mana_value: 2}
      }

      decoded = deck |> DecksHelpers.mana_curve_series(cards_by_arena_id) |> Jason.decode!()

      assert Enum.find(decoded, fn [label, _] -> label == "1" end) == ["1", 4]
      assert Enum.find(decoded, fn [label, _] -> label == "2" end) == ["2", 2]
    end

    test "caps mana values at 7+" do
      deck = %{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 1, "count" => 2}]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Emrakul", types: "Creature", mana_value: 15}
      }

      decoded = deck |> DecksHelpers.mana_curve_series(cards_by_arena_id) |> Jason.decode!()

      assert Enum.find(decoded, fn [label, _] -> label == "7+" end) == ["7+", 2]
    end
  end

  describe "group_cards_by_cmc/2" do
    test "groups cards by mana value, lands last" do
      deck = %{
        current_main_deck: %{
          "cards" => [
            %{"arena_id" => 1, "count" => 4},
            %{"arena_id" => 2, "count" => 2},
            %{"arena_id" => 3, "count" => 24}
          ]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Lightning Bolt", types: "Instant", mana_value: 1},
        2 => %{name: "Counterspell", types: "Instant", mana_value: 2},
        3 => %{name: "Mountain", types: "Basic Land", mana_value: 0}
      }

      groups = DecksHelpers.group_cards_by_cmc(deck, cards_by_arena_id)
      labels = Enum.map(groups, fn {label, _} -> label end)

      assert "1" in labels
      assert "2" in labels
      assert "Land" in labels
      # Lands must be last
      assert List.last(labels) == "Land"
      # Non-lands come before lands
      assert Enum.find_index(labels, &(&1 == "1")) < Enum.find_index(labels, &(&1 == "Land"))
    end

    test "preserves card count" do
      deck = %{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 1, "count" => 4}]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Lightning Bolt", types: "Instant", mana_value: 1}
      }

      [{_label, cards}] = DecksHelpers.group_cards_by_cmc(deck, cards_by_arena_id)
      assert List.first(cards).count == 4
    end

    test "returns empty list when deck has no cards" do
      deck = %{current_main_deck: %{"cards" => []}}
      assert DecksHelpers.group_cards_by_cmc(deck, %{}) == []
    end

    test "unknown card data defaults to CMC 0, non-land" do
      deck = %{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 999, "count" => 1}]
        }
      }

      [{label, cards}] = DecksHelpers.group_cards_by_cmc(deck, %{})
      assert label == "0"
      assert List.first(cards).count == 1
    end

    test "cards with CMC >= 7 are grouped under 7+" do
      deck = %{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 1, "count" => 1}]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Emrakul", types: "Creature", mana_value: 15}
      }

      [{label, _}] = DecksHelpers.group_cards_by_cmc(deck, cards_by_arena_id)
      assert label == "7+"
    end
  end

  describe "sideboard_cards/2" do
    test "returns empty list when sideboard is absent" do
      deck = %{current_sideboard: nil}
      assert DecksHelpers.sideboard_cards(deck, %{}) == []
    end

    test "returns empty list when sideboard has no cards key" do
      deck = %{current_sideboard: %{}}
      assert DecksHelpers.sideboard_cards(deck, %{}) == []
    end

    test "resolves card names from cards_by_arena_id" do
      deck = %{current_sideboard: %{"cards" => [%{"arena_id" => 1, "count" => 2}]}}
      cards_by_arena_id = %{1 => %{name: "Negate", types: "Instant", mana_value: 2}}

      [card] = DecksHelpers.sideboard_cards(deck, cards_by_arena_id)
      assert card.arena_id == 1
      assert card.count == 2
      assert card.name == "Negate"
    end

    test "falls back to stringified arena_id for unknown cards" do
      deck = %{current_sideboard: %{"cards" => [%{"arena_id" => 99999, "count" => 1}]}}

      [card] = DecksHelpers.sideboard_cards(deck, %{})
      assert card.name == "99999"
    end

    test "sorts by mana value then name" do
      deck = %{
        current_sideboard: %{
          "cards" => [
            %{"arena_id" => 3, "count" => 1},
            %{"arena_id" => 1, "count" => 2},
            %{"arena_id" => 2, "count" => 3}
          ]
        }
      }

      cards_by_arena_id = %{
        1 => %{name: "Negate", types: "Instant", mana_value: 2},
        2 => %{name: "Disdainful Stroke", types: "Instant", mana_value: 2},
        3 => %{name: "Tormod's Crypt", types: "Artifact", mana_value: 0}
      }

      cards = DecksHelpers.sideboard_cards(deck, cards_by_arena_id)
      names = Enum.map(cards, & &1.name)

      # mana_value 0 first, then mana_value 2 (alphabetical: Disdainful before Negate)
      assert names == ["Tormod's Crypt", "Disdainful Stroke", "Negate"]
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
