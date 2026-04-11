defmodule Scry2.Cards.BootstrapTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.Bootstrap

  @now ~U[2026-04-11 12:00:00Z]
  @fresh ~U[2026-04-05 12:00:00Z]
  @old ~U[2026-04-01 12:00:00Z]

  describe "stale?/2" do
    test "nil is always stale" do
      assert Bootstrap.stale?(nil, @now)
    end

    test "timestamp within 7 days is fresh" do
      refute Bootstrap.stale?(@fresh, @now)
    end

    test "exactly 7 days old is still fresh" do
      seven_days = ~U[2026-04-04 12:00:00Z]
      refute Bootstrap.stale?(seven_days, @now)
    end

    test "older than 7 days is stale" do
      assert Bootstrap.stale?(@old, @now)
    end
  end

  describe "needs?/3" do
    test "count of zero always needs a refresh" do
      assert Bootstrap.needs?(0, @fresh, @now)
    end

    test "count > 0 with fresh timestamp does not need a refresh" do
      refute Bootstrap.needs?(10, @fresh, @now)
    end

    test "count > 0 with stale timestamp needs a refresh" do
      assert Bootstrap.needs?(10, @old, @now)
    end

    test "count > 0 with nil timestamp needs a refresh" do
      assert Bootstrap.needs?(10, nil, @now)
    end
  end

  describe "decide/4" do
    test "enqueues both when both sources are empty" do
      timestamps = %{lands17_updated_at: nil, scryfall_updated_at: nil}
      assert Bootstrap.decide(0, 0, timestamps, @now) == [:lands17, :scryfall]
    end

    test "enqueues neither when both are fresh" do
      timestamps = %{lands17_updated_at: @fresh, scryfall_updated_at: @fresh}
      assert Bootstrap.decide(100, 100, timestamps, @now) == []
    end

    test "enqueues only 17lands when Scryfall is fresh but 17lands is missing" do
      timestamps = %{lands17_updated_at: nil, scryfall_updated_at: @fresh}
      assert Bootstrap.decide(0, 100, timestamps, @now) == [:lands17]
    end

    test "enqueues only Scryfall when 17lands is fresh but Scryfall is missing" do
      timestamps = %{lands17_updated_at: @fresh, scryfall_updated_at: nil}
      assert Bootstrap.decide(100, 0, timestamps, @now) == [:scryfall]
    end

    test "enqueues both when both are stale" do
      timestamps = %{lands17_updated_at: @old, scryfall_updated_at: @old}
      assert Bootstrap.decide(100, 100, timestamps, @now) == [:lands17, :scryfall]
    end

    test "enqueues only the stale one when the other is fresh" do
      timestamps = %{lands17_updated_at: @old, scryfall_updated_at: @fresh}
      assert Bootstrap.decide(100, 100, timestamps, @now) == [:lands17]
    end
  end
end
