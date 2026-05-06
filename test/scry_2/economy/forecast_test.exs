defmodule Scry2.Economy.ForecastTest do
  use ExUnit.Case, async: true

  alias Scry2.Economy.Forecast

  defp snap(occurred_at, fields) do
    Map.merge(%{occurred_at: occurred_at}, fields)
  end

  describe "net_change/2" do
    test "returns last - first for the given field" do
      snapshots = [
        snap(~U[2026-04-25 00:00:00Z], %{gold: 5_000}),
        snap(~U[2026-04-30 00:00:00Z], %{gold: 4_200}),
        snap(~U[2026-05-02 00:00:00Z], %{gold: 3_800})
      ]

      assert Forecast.net_change(snapshots, :gold) == -1_200
    end

    test "treats nil values as zero" do
      snapshots = [
        snap(~U[2026-04-25 00:00:00Z], %{gold: nil}),
        snap(~U[2026-05-02 00:00:00Z], %{gold: 1_000})
      ]

      assert Forecast.net_change(snapshots, :gold) == 1_000
    end

    test "returns 0 with fewer than two snapshots" do
      assert Forecast.net_change([], :gold) == 0
      assert Forecast.net_change([snap(~U[2026-05-02 00:00:00Z], %{gold: 1_000})], :gold) == 0
    end
  end

  describe "daily_rate/2" do
    test "returns average daily change across the snapshot window" do
      snapshots = [
        snap(~U[2026-04-25 00:00:00Z], %{gold: 5_000}),
        snap(~U[2026-05-02 00:00:00Z], %{gold: 1_500})
      ]

      # -3500 over 7 days = -500/day
      assert Forecast.daily_rate(snapshots, :gold) == -500.0
    end

    test "handles fractional days" do
      snapshots = [
        snap(~U[2026-05-01 00:00:00Z], %{gems: 100}),
        snap(~U[2026-05-02 12:00:00Z], %{gems: 250})
      ]

      # +150 over 1.5 days = +100.0/day
      assert Forecast.daily_rate(snapshots, :gems) == 100.0
    end

    test "returns 0.0 when window is too short to estimate" do
      assert Forecast.daily_rate([], :gold) == 0.0
      assert Forecast.daily_rate([snap(~U[2026-05-02 00:00:00Z], %{gold: 1})], :gold) == 0.0
    end

    test "returns 0.0 when first and last snapshots share a timestamp" do
      ts = ~U[2026-05-02 00:00:00Z]
      snapshots = [snap(ts, %{gold: 1_000}), snap(ts, %{gold: 1_500})]
      assert Forecast.daily_rate(snapshots, :gold) == 0.0
    end
  end

  describe "vault_eta/2" do
    test "returns the date vault_progress reaches 100% at the current rate" do
      now = ~U[2026-05-02 00:00:00Z]

      snapshots = [
        snap(~U[2026-04-25 00:00:00Z], %{vault_progress: 30.0}),
        snap(~U[2026-05-02 00:00:00Z], %{vault_progress: 44.0})
      ]

      # +14% over 7 days = +2%/day → 56% remaining ÷ 2%/day = 28 days
      assert Forecast.vault_eta(snapshots, now) ==
               %{eta: ~U[2026-05-30 00:00:00Z], days: 28.0, rate_per_day: 2.0}
    end

    test "returns :already_full when latest snapshot is at 100" do
      now = ~U[2026-05-02 00:00:00Z]

      snapshots = [
        snap(~U[2026-04-25 00:00:00Z], %{vault_progress: 99.0}),
        snap(~U[2026-05-02 00:00:00Z], %{vault_progress: 100.0})
      ]

      assert Forecast.vault_eta(snapshots, now) == :already_full
    end

    test "returns :no_progress when the rate is zero or negative" do
      now = ~U[2026-05-02 00:00:00Z]

      flat = [
        snap(~U[2026-04-25 00:00:00Z], %{vault_progress: 50.0}),
        snap(~U[2026-05-02 00:00:00Z], %{vault_progress: 50.0})
      ]

      assert Forecast.vault_eta(flat, now) == :no_progress

      decreasing = [
        snap(~U[2026-04-25 00:00:00Z], %{vault_progress: 50.0}),
        snap(~U[2026-05-02 00:00:00Z], %{vault_progress: 40.0})
      ]

      assert Forecast.vault_eta(decreasing, now) == :no_progress
    end

    test "returns :insufficient_data when fewer than two snapshots have vault_progress" do
      now = ~U[2026-05-02 00:00:00Z]

      assert Forecast.vault_eta([], now) == :insufficient_data

      one = [snap(~U[2026-05-02 00:00:00Z], %{vault_progress: 30.0})]
      assert Forecast.vault_eta(one, now) == :insufficient_data

      missing = [
        snap(~U[2026-04-25 00:00:00Z], %{vault_progress: nil}),
        snap(~U[2026-05-02 00:00:00Z], %{vault_progress: 30.0})
      ]

      assert Forecast.vault_eta(missing, now) == :insufficient_data
    end
  end

  describe "mastery_eta/2" do
    defp mastery(occurred_at, tier, xp, ends_at \\ ~U[2026-06-01 00:00:00Z]) do
      %{
        occurred_at: occurred_at,
        mastery_tier: tier,
        mastery_xp_in_tier: xp,
        mastery_season_ends_at: ends_at
      }
    end

    test "projects tier at season end from current XP-per-day rate" do
      now = ~U[2026-05-02 00:00:00Z]
      ends_at = ~U[2026-06-01 00:00:00Z]

      # tier 30 → tier 35 + 0 xp over 7 days = +5_000 XP / 7d ≈ 714.29/day
      # 30 days remaining → +21,428.57 XP → +21 tiers → projected tier 56
      snapshots = [
        mastery(~U[2026-04-25 00:00:00Z], 30, 0, ends_at),
        mastery(~U[2026-05-02 00:00:00Z], 35, 0, ends_at)
      ]

      result = Forecast.mastery_eta(snapshots, now)

      assert result.projected_tier_at_season_end == 56
      assert_in_delta result.xp_per_day, 714.285, 0.01
      assert result.season_ends_at == ends_at
      # 1000 xp to next tier ÷ 714/day ≈ 1.4 days
      assert_in_delta result.days_to_next_tier, 1.4, 0.05
    end

    test "uses current xp_in_tier in days_to_next_tier" do
      now = ~U[2026-05-02 00:00:00Z]
      ends_at = ~U[2026-06-01 00:00:00Z]

      # last snapshot: tier 35, xp 750. Rate: +1000 xp/day → 250 xp ÷ 1000 = 0.25 days
      snapshots = [
        mastery(~U[2026-04-25 00:00:00Z], 28, 750, ends_at),
        mastery(~U[2026-05-02 00:00:00Z], 35, 750, ends_at)
      ]

      result = Forecast.mastery_eta(snapshots, now)
      assert_in_delta result.days_to_next_tier, 0.25, 0.001
    end

    test "returns :no_progress when XP rate is flat or decreasing" do
      now = ~U[2026-05-02 00:00:00Z]
      ends_at = ~U[2026-06-01 00:00:00Z]

      flat = [
        mastery(~U[2026-04-25 00:00:00Z], 30, 500, ends_at),
        mastery(~U[2026-05-02 00:00:00Z], 30, 500, ends_at)
      ]

      assert Forecast.mastery_eta(flat, now) == :no_progress

      # MTGA does not actually decrease XP, but the function should be safe.
      decreasing = [
        mastery(~U[2026-04-25 00:00:00Z], 31, 0, ends_at),
        mastery(~U[2026-05-02 00:00:00Z], 30, 0, ends_at)
      ]

      assert Forecast.mastery_eta(decreasing, now) == :no_progress
    end

    test "returns :insufficient_data when fewer than two snapshots have mastery fields" do
      now = ~U[2026-05-02 00:00:00Z]

      assert Forecast.mastery_eta([], now) == :insufficient_data

      one = [mastery(~U[2026-05-02 00:00:00Z], 30, 500)]
      assert Forecast.mastery_eta(one, now) == :insufficient_data

      missing = [
        mastery(~U[2026-04-25 00:00:00Z], nil, nil),
        mastery(~U[2026-05-02 00:00:00Z], 30, 500)
      ]

      assert Forecast.mastery_eta(missing, now) == :insufficient_data
    end

    test "returns :season_ended when now is past the season end" do
      now = ~U[2026-06-15 00:00:00Z]
      ends_at = ~U[2026-06-01 00:00:00Z]

      snapshots = [
        mastery(~U[2026-04-25 00:00:00Z], 30, 0, ends_at),
        mastery(~U[2026-05-02 00:00:00Z], 35, 0, ends_at)
      ]

      assert Forecast.mastery_eta(snapshots, now) == :season_ended
    end

    test "returns :no_season_end when latest snapshot has nil season_ends_at" do
      now = ~U[2026-05-02 00:00:00Z]

      snapshots = [
        mastery(~U[2026-04-25 00:00:00Z], 30, 0, nil),
        mastery(~U[2026-05-02 00:00:00Z], 35, 0, nil)
      ]

      assert Forecast.mastery_eta(snapshots, now) == :no_season_end
    end

    test "ignores snapshots before the first one with mastery data" do
      now = ~U[2026-05-02 00:00:00Z]
      ends_at = ~U[2026-06-01 00:00:00Z]

      # Walker lit up partway through the snapshot history. Only mastery-bearing
      # rows count toward the rate calculation.
      snapshots = [
        mastery(~U[2026-04-15 00:00:00Z], nil, nil, nil),
        mastery(~U[2026-04-20 00:00:00Z], nil, nil, nil),
        mastery(~U[2026-04-25 00:00:00Z], 30, 0, ends_at),
        mastery(~U[2026-05-02 00:00:00Z], 35, 0, ends_at)
      ]

      result = Forecast.mastery_eta(snapshots, now)
      assert is_map(result)
      assert_in_delta result.xp_per_day, 714.285, 0.01
    end
  end
end
