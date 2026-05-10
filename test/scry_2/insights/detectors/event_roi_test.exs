defmodule Scry2.Insights.Detectors.EventROITest do
  use Scry2.DataCase, async: true

  alias Scry2.Economy.EventEntry
  alias Scry2.Insights.Detectors.EventROI
  alias Scry2.Insights.Insight
  alias Scry2.Repo

  defp insert_event_entry!(overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    defaults = %{
      event_name: "Event-#{System.unique_integer([:positive])}",
      event_type: "premier_draft",
      entry_currency_type: "gems",
      entry_fee: 1500,
      joined_at: DateTime.add(now, -7, :day),
      final_wins: 3,
      final_losses: 3,
      gems_awarded: 800,
      gold_awarded: 0,
      claimed_at: DateTime.add(now, -6, :day)
    }

    attrs = Map.merge(defaults, overrides)

    %EventEntry{}
    |> EventEntry.changeset(attrs)
    |> Repo.insert!()
  end

  describe "tier/0" do
    test "is tier 1" do
      assert EventROI.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil when no event entries" do
      assert EventROI.detect([]) == nil
    end

    test "returns nil when only positive ROI event types" do
      for _ <- 1..5 do
        insert_event_entry!(%{
          event_type: "quick_draft",
          entry_fee: 750,
          gems_awarded: 950
        })
      end

      assert EventROI.detect([]) == nil
    end

    test "returns nil when negative net but below the minimum events threshold" do
      for _ <- 1..2 do
        insert_event_entry!(%{event_type: "premier_draft", entry_fee: 1500, gems_awarded: 800})
      end

      assert EventROI.detect([]) == nil
    end

    test "ignores entries outside the lookback window" do
      old = DateTime.utc_now() |> DateTime.add(-90, :day) |> DateTime.truncate(:second)

      for _ <- 1..5 do
        insert_event_entry!(%{
          event_type: "premier_draft",
          entry_fee: 1500,
          gems_awarded: 0,
          joined_at: old,
          claimed_at: old
        })
      end

      assert EventROI.detect([]) == nil
    end

    test "ignores entries that haven't been claimed" do
      for _ <- 1..5 do
        insert_event_entry!(%{
          event_type: "premier_draft",
          entry_fee: 1500,
          gems_awarded: 0,
          claimed_at: nil
        })
      end

      assert EventROI.detect([]) == nil
    end

    test "ignores non-gems entry currencies" do
      for _ <- 1..5 do
        insert_event_entry!(%{
          event_type: "premier_draft",
          entry_currency_type: "gold",
          entry_fee: 10_000,
          gems_awarded: 0
        })
      end

      assert EventROI.detect([]) == nil
    end

    test "selects the event type with most negative net when multiple qualify" do
      # premier_draft: 3 entries × (800 - 1500) = -2100 total
      for _ <- 1..3,
          do:
            insert_event_entry!(%{
              event_type: "premier_draft",
              entry_fee: 1500,
              gems_awarded: 800
            })

      # sealed: 4 entries × (1200 - 2000) = -3200 total — worse, should win
      for _ <- 1..4,
          do: insert_event_entry!(%{event_type: "sealed", entry_fee: 2000, gems_awarded: 1200})

      # quick_draft: 3 entries × (950 - 750) = +600 total — should not be picked
      for _ <- 1..3,
          do: insert_event_entry!(%{event_type: "quick_draft", entry_fee: 750, gems_awarded: 950})

      insight = EventROI.detect([])

      assert %Insight{} = insight
      assert insight.detector == "EventROI"
      assert insight.surface == "home"
      assert insight.tier == 1
      assert insight.measurements["event_type"] == "sealed"
      assert insight.measurements["net_gems"] == -3200
      assert insight.measurements["events_count"] == 4
      assert insight.measurements["gems_spent"] == 8000
      assert insight.measurements["gems_earned"] == 4800
      assert insight.sample_size == 4

      assert insight.stats["primary"]["num"] == "-3200"
      assert insight.stats["tertiary"]["num"] == "n=4"
    end
  end
end
