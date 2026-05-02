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
end
