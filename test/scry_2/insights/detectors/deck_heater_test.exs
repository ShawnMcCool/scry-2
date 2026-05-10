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

      # Heater: 12-1 over the last 5 days
      for _ <- 1..12 do
        TestFactory.create_match(%{
          won: true,
          mtga_deck_id: "heater-deck",
          deck_name: "Esper Heater",
          started_at: DateTime.add(now, -3, :day)
        })
      end

      for _ <- 1..1 do
        TestFactory.create_match(%{
          won: false,
          mtga_deck_id: "heater-deck",
          deck_name: "Esper Heater",
          started_at: DateTime.add(now, -3, :day)
        })
      end

      assert %Insight{} = insight = DeckHeater.detect([])
      assert insight.tier == 2
      assert insight.measurements["mtga_deck_id"] == "heater-deck"
      assert insight.measurements["deck_name"] == "Esper Heater"
      assert insight.measurements["deck_n"] == 13
      assert insight.confidence < 0.10
    end
  end
end
