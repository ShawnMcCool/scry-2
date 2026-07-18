defmodule Scry2.Insights.Detectors.DeckHeaterTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.DeckHeater
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  describe "tier/0" do
    test "is tier 2" do
      assert DeckHeater.tier() == 2
    end
  end

  describe "detect/1" do
    test "returns nil when baseline below minimum" do
      for _ <- 1..10, do: TestFactory.create_match(%{won: true})
      assert DeckHeater.detect([]) == nil
    end

    test "returns nil when no deck has enough recent matches" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      # Build baseline of 30 matches (no specific deck) at older time
      for _ <- 1..30 do
        TestFactory.create_match(%{
          won: false,
          mtga_deck_id: "old-deck",
          deck_name: "Old",
          started_at: DateTime.add(now, -30, :day)
        })
      end

      assert DeckHeater.detect([]) == nil
    end

    test "returns insight for a deck whose 7d WR significantly beats the baseline" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Baseline: 60 matches over the past 30 days, ~50% WR
      for _ <- 1..30 do
        TestFactory.create_match(%{
          won: true,
          mtga_deck_id: "baseline-#{System.unique_integer([:positive])}",
          deck_name: "Baseline",
          started_at: DateTime.add(now, -20, :day)
        })
      end

      for _ <- 1..30 do
        TestFactory.create_match(%{
          won: false,
          mtga_deck_id: "baseline-#{System.unique_integer([:positive])}",
          deck_name: "Baseline",
          started_at: DateTime.add(now, -20, :day)
        })
      end

      # Heater: 12-1 over the last few days, played as ONE decklist that is split
      # across two Island printings — heater-b is most recently played (canonical).
      TestFactory.create_card(arena_id: 105_175, name: "Island")
      TestFactory.create_card(arena_id: 102_727, name: "Island")

      heater_a =
        TestFactory.create_deck(%{
          mtga_deck_id: "heater-a",
          current_name: "Old Name",
          current_main_deck: %{"cards" => [%{"arena_id" => 105_175, "count" => 60}]},
          last_played_at: DateTime.add(now, -6, :day)
        })

      heater_b =
        TestFactory.create_deck(%{
          mtga_deck_id: "heater-b",
          current_name: "Esper Heater",
          current_main_deck: %{"cards" => [%{"arena_id" => 102_727, "count" => 60}]},
          last_played_at: DateTime.add(now, -2, :day)
        })

      played_at = DateTime.add(now, -3, :day)

      heater_match = fn deck, won, tag ->
        match_id = "heater-#{tag}"
        # A match played with `deck`: the match row (matches_matches) plus the
        # deck attribution (decks_match_results) the resolver reads.
        TestFactory.create_match(%{won: won, mtga_match_id: match_id, started_at: played_at})

        TestFactory.create_deck_match_result(%{
          deck: deck,
          mtga_match_id: match_id,
          won: won,
          started_at: played_at
        })
      end

      # 12 wins split across the two printings + 1 loss = one decklist, 13 matches.
      for i <- 1..6, do: heater_match.(heater_a, true, "a#{i}")
      for i <- 1..6, do: heater_match.(heater_b, true, "b#{i}")
      heater_match.(heater_b, false, "loss")

      assert %Insight{} = insight = DeckHeater.detect([])
      assert insight.tier == 2
      # Both printings unite under the canonical decklist (heater-b).
      assert insight.measurements["mtga_deck_id"] == "heater-b"
      assert insight.measurements["deck_name"] == "Esper Heater"
      assert insight.measurements["deck_n"] == 13
      assert insight.confidence < 0.10
    end
  end
end
