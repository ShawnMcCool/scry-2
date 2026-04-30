defmodule Scry2.MatchEconomy.ComputeTest do
  use ExUnit.Case, async: true
  alias Scry2.Collection.Snapshot
  alias Scry2.MatchEconomy.Compute

  describe "memory_deltas/2" do
    test "subtracts post − pre for each currency" do
      pre = %Snapshot{
        gold: 1000,
        gems: 50,
        wildcards_common: 10,
        wildcards_uncommon: 5,
        wildcards_rare: 3,
        wildcards_mythic: 1,
        vault_progress: 0.20
      }

      post = %Snapshot{
        gold: 1250,
        gems: 50,
        wildcards_common: 11,
        wildcards_uncommon: 5,
        wildcards_rare: 3,
        wildcards_mythic: 1,
        vault_progress: 0.25
      }

      assert Compute.memory_deltas(pre, post) == %{
               gold: 250,
               gems: 0,
               wildcards_common: 1,
               wildcards_uncommon: 0,
               wildcards_rare: 0,
               wildcards_mythic: 0,
               vault: 0.05
             }
    end

    test "returns all-nil map when pre is nil" do
      post = %Snapshot{
        gold: 100,
        gems: 0,
        wildcards_common: 0,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault_progress: 0.0
      }

      assert Compute.memory_deltas(nil, post) == nil_delta_map()
    end

    test "returns all-nil map when post is nil" do
      pre = %Snapshot{
        gold: 100,
        gems: 0,
        wildcards_common: 0,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault_progress: 0.0
      }

      assert Compute.memory_deltas(pre, nil) == nil_delta_map()
    end

    test "passes nil through when a single field is nil on either side" do
      pre = %Snapshot{
        gold: 100,
        gems: 50,
        wildcards_common: nil,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault_progress: 0.0
      }

      post = %Snapshot{
        gold: 200,
        gems: 50,
        wildcards_common: nil,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault_progress: 0.0
      }

      result = Compute.memory_deltas(pre, post)
      assert result.gold == 100
      assert result.wildcards_common == nil
    end
  end

  describe "diffs/2" do
    test "subtracts log delta from memory delta per currency" do
      memory = %{
        gold: 250,
        gems: 0,
        wildcards_common: 1,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault: 0.05
      }

      log = %{
        gold: 250,
        gems: 0,
        wildcards_common: 1,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0
      }

      assert Compute.diffs(memory, log) == %{
               gold: 0,
               gems: 0,
               wildcards_common: 0,
               wildcards_uncommon: 0,
               wildcards_rare: 0,
               wildcards_mythic: 0
             }
    end

    test "returns nil for currencies missing on either side" do
      memory = %{
        gold: 250,
        gems: 0,
        wildcards_common: nil,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault: 0.0
      }

      log = %{
        gold: nil,
        gems: 0,
        wildcards_common: 1,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0
      }

      result = Compute.diffs(memory, log)
      assert result.gold == nil
      assert result.wildcards_common == nil
      assert result.gems == 0
    end

    test "non-zero diff signals memory accounting more than logs do" do
      memory = %{
        gold: 300,
        gems: 0,
        wildcards_common: 0,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0,
        vault: 0.0
      }

      log = %{
        gold: 250,
        gems: 0,
        wildcards_common: 0,
        wildcards_uncommon: 0,
        wildcards_rare: 0,
        wildcards_mythic: 0
      }

      assert Compute.diffs(memory, log).gold == 50
    end
  end

  defp nil_delta_map do
    %{
      gold: nil,
      gems: nil,
      wildcards_common: nil,
      wildcards_uncommon: nil,
      wildcards_rare: nil,
      wildcards_mythic: nil,
      vault: nil
    }
  end
end
