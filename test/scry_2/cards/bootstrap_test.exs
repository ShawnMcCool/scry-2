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
    @empty_counts %{lands17: 0, scryfall: 0, mtga_client: 0}
    @fresh_timestamps %{
      lands17_updated_at: @fresh,
      scryfall_updated_at: @fresh,
      mtga_client_updated_at: @fresh
    }

    test "enqueues all sources when all are empty" do
      timestamps = %{
        lands17_updated_at: nil,
        scryfall_updated_at: nil,
        mtga_client_updated_at: nil
      }

      assert Bootstrap.decide(@empty_counts, timestamps, @now) ==
               [:lands17, :scryfall, :mtga_client]
    end

    test "enqueues nothing when all sources are fresh" do
      counts = %{lands17: 100, scryfall: 100, mtga_client: 100}
      assert Bootstrap.decide(counts, @fresh_timestamps, @now) == []
    end

    test "enqueues only 17lands when only its source is missing" do
      timestamps = %{
        lands17_updated_at: nil,
        scryfall_updated_at: @fresh,
        mtga_client_updated_at: @fresh
      }

      counts = %{lands17: 0, scryfall: 100, mtga_client: 100}
      assert Bootstrap.decide(counts, timestamps, @now) == [:lands17]
    end

    test "enqueues only Scryfall when only its source is missing" do
      timestamps = %{
        lands17_updated_at: @fresh,
        scryfall_updated_at: nil,
        mtga_client_updated_at: @fresh
      }

      counts = %{lands17: 100, scryfall: 0, mtga_client: 100}
      assert Bootstrap.decide(counts, timestamps, @now) == [:scryfall]
    end

    test "enqueues only mtga_client when only its source is missing" do
      timestamps = %{
        lands17_updated_at: @fresh,
        scryfall_updated_at: @fresh,
        mtga_client_updated_at: nil
      }

      counts = %{lands17: 100, scryfall: 100, mtga_client: 0}
      assert Bootstrap.decide(counts, timestamps, @now) == [:mtga_client]
    end

    test "enqueues all stale sources" do
      timestamps = %{
        lands17_updated_at: @old,
        scryfall_updated_at: @old,
        mtga_client_updated_at: @old
      }

      counts = %{lands17: 100, scryfall: 100, mtga_client: 100}

      assert Bootstrap.decide(counts, timestamps, @now) ==
               [:lands17, :scryfall, :mtga_client]
    end

    test "enqueues only the stale one when others are fresh" do
      timestamps = %{
        lands17_updated_at: @old,
        scryfall_updated_at: @fresh,
        mtga_client_updated_at: @fresh
      }

      counts = %{lands17: 100, scryfall: 100, mtga_client: 100}
      assert Bootstrap.decide(counts, timestamps, @now) == [:lands17]
    end
  end
end
