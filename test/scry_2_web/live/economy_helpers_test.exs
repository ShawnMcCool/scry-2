defmodule Scry2Web.EconomyHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.EconomyHelpers

  describe "format_currency/2" do
    test "formats amount with label" do
      assert EconomyHelpers.format_currency(1500, "Gems") == "1,500 Gems"
    end

    test "returns dash for nil" do
      assert EconomyHelpers.format_currency(nil, "Gold") == "—"
    end
  end

  describe "format_delta/1" do
    test "positive amounts get plus sign" do
      assert EconomyHelpers.format_delta(500) == "+500"
    end

    test "negative amounts keep minus sign" do
      assert EconomyHelpers.format_delta(-200) == "-200"
    end

    test "zero returns zero" do
      assert EconomyHelpers.format_delta(0) == "0"
    end

    test "nil returns dash" do
      assert EconomyHelpers.format_delta(nil) == "—"
    end
  end

  describe "delta_class/1" do
    test "positive is green" do
      assert EconomyHelpers.delta_class(100) =~ "emerald"
    end

    test "negative is red" do
      assert EconomyHelpers.delta_class(-100) =~ "red"
    end
  end

  describe "format_roi/1" do
    test "in-progress entry" do
      assert EconomyHelpers.format_roi(%{claimed_at: nil}) == "In progress"
    end

    test "gem entry with profit" do
      entry = %{
        entry_fee: 1500,
        entry_currency_type: "Gems",
        gems_awarded: 2000,
        gold_awarded: 1000,
        claimed_at: ~U[2026-04-08 12:00:00Z]
      }

      assert EconomyHelpers.format_roi(entry) == "+500 Gems"
    end

    test "gold entry with loss" do
      entry = %{
        entry_fee: 500,
        entry_currency_type: "Gold",
        gems_awarded: 0,
        gold_awarded: 100,
        claimed_at: ~U[2026-04-08 12:00:00Z]
      }

      assert EconomyHelpers.format_roi(entry) == "-400 Gold"
    end
  end

  describe "format_number/1" do
    test "adds comma separators" do
      assert EconomyHelpers.format_number(1_500_000) == "1,500,000"
    end

    test "small numbers unchanged" do
      assert EconomyHelpers.format_number(42) == "42"
    end

    test "negative numbers" do
      assert EconomyHelpers.format_number(-1500) == "-1,500"
    end
  end

  # ── Chart series helpers ─────────────────────────────────────────

  defp snapshot(attrs) do
    Map.merge(
      %{
        gold: 10_000,
        gems: 500,
        wildcards_common: 20,
        wildcards_uncommon: 15,
        wildcards_rare: 5,
        wildcards_mythic: 2,
        occurred_at: ~U[2026-04-10 12:00:00Z]
      },
      attrs
    )
  end

  describe "currency_series/1" do
    test "returns empty series for empty list" do
      assert EconomyHelpers.currency_series([]) == %{gold: [], gems: []}
    end

    test "builds gold and gems series from snapshots" do
      snapshots = [
        snapshot(%{gold: 5000, gems: 200, occurred_at: ~U[2026-04-10 10:00:00Z]}),
        snapshot(%{gold: 6500, gems: 150, occurred_at: ~U[2026-04-10 14:00:00Z]})
      ]

      result = EconomyHelpers.currency_series(snapshots)

      assert result.gold == [
               ["2026-04-10T10:00:00Z", 5000],
               ["2026-04-10T14:00:00Z", 6500]
             ]

      assert result.gems == [
               ["2026-04-10T10:00:00Z", 200],
               ["2026-04-10T14:00:00Z", 150]
             ]
    end

    test "defaults nil values to 0" do
      snapshots = [snapshot(%{gold: nil, gems: nil})]
      result = EconomyHelpers.currency_series(snapshots)

      assert result.gold == [["2026-04-10T12:00:00Z", 0]]
      assert result.gems == [["2026-04-10T12:00:00Z", 0]]
    end
  end

  describe "wildcards_series/1" do
    test "returns empty series for empty list" do
      result = EconomyHelpers.wildcards_series([])
      assert result == %{common: [], uncommon: [], rare: [], mythic: []}
    end

    test "builds four rarity series from snapshots" do
      snapshots = [
        snapshot(%{
          wildcards_common: 65,
          wildcards_uncommon: 78,
          wildcards_rare: 3,
          wildcards_mythic: 12,
          occurred_at: ~U[2026-04-10 10:00:00Z]
        }),
        snapshot(%{
          wildcards_common: 60,
          wildcards_uncommon: 80,
          wildcards_rare: 2,
          wildcards_mythic: 12,
          occurred_at: ~U[2026-04-10 14:00:00Z]
        })
      ]

      result = EconomyHelpers.wildcards_series(snapshots)

      assert result.common == [
               ["2026-04-10T10:00:00Z", 65],
               ["2026-04-10T14:00:00Z", 60]
             ]

      assert result.rare == [
               ["2026-04-10T10:00:00Z", 3],
               ["2026-04-10T14:00:00Z", 2]
             ]
    end

    test "defaults nil values to 0" do
      snapshots = [
        snapshot(%{
          wildcards_common: nil,
          wildcards_uncommon: nil,
          wildcards_rare: nil,
          wildcards_mythic: nil
        })
      ]

      result = EconomyHelpers.wildcards_series(snapshots)

      assert result.common == [["2026-04-10T12:00:00Z", 0]]
      assert result.mythic == [["2026-04-10T12:00:00Z", 0]]
    end
  end

  describe "filter_snapshots_to_range/2" do
    test "season returns all snapshots" do
      snapshots = [snapshot(%{}), snapshot(%{})]
      assert EconomyHelpers.filter_snapshots_to_range(snapshots, "season") == snapshots
    end

    test "today filters to current UTC date" do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -1, :day)

      snapshots = [
        snapshot(%{occurred_at: yesterday}),
        snapshot(%{occurred_at: today})
      ]

      result = EconomyHelpers.filter_snapshots_to_range(snapshots, "today")
      assert length(result) == 1
      assert hd(result).occurred_at == today
    end

    test "week filters to last 7 days" do
      now = DateTime.utc_now()
      three_days_ago = DateTime.add(now, -3, :day)
      ten_days_ago = DateTime.add(now, -10, :day)

      snapshots = [
        snapshot(%{occurred_at: ten_days_ago}),
        snapshot(%{occurred_at: three_days_ago}),
        snapshot(%{occurred_at: now})
      ]

      result = EconomyHelpers.filter_snapshots_to_range(snapshots, "week")
      assert length(result) == 2
    end
  end
end
