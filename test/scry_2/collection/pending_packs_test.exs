defmodule Scry2.Collection.PendingPacksTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.PendingPacks
  alias Scry2.Collection.Snapshot

  defp lookup_fn(mapping) do
    fn collation_id -> Map.get(mapping, collation_id) end
  end

  describe "summarize/2" do
    test "returns rows grouped by set_code, sorted by count desc" do
      snapshot = %Snapshot{
        boosters_json:
          Snapshot.encode_boosters([
            %{collation_id: 100_046, count: 3},
            %{collation_id: 100_052, count: 7}
          ])
      }

      lookup = lookup_fn(%{100_046 => "BLB", 100_052 => "DFT"})

      assert PendingPacks.summarize(snapshot, lookup) ==
               [
                 %{set_code: "DFT", count: 7},
                 %{set_code: "BLB", count: 3}
               ]
    end

    test "merges multiple collation_ids that resolve to the same set_code" do
      snapshot = %Snapshot{
        boosters_json:
          Snapshot.encode_boosters([
            %{collation_id: 100_046, count: 3},
            %{collation_id: 200_046, count: 2}
          ])
      }

      lookup = lookup_fn(%{100_046 => "BLB", 200_046 => "BLB"})

      assert PendingPacks.summarize(snapshot, lookup) ==
               [%{set_code: "BLB", count: 5}]
    end

    test "groups unknown collation_ids under set_code: nil" do
      snapshot = %Snapshot{
        boosters_json:
          Snapshot.encode_boosters([
            %{collation_id: 100_046, count: 3},
            %{collation_id: 999_999, count: 1}
          ])
      }

      lookup = lookup_fn(%{100_046 => "BLB"})

      assert PendingPacks.summarize(snapshot, lookup) ==
               [
                 %{set_code: "BLB", count: 3},
                 %{set_code: nil, count: 1}
               ]
    end

    test "drops zero-count rows" do
      snapshot = %Snapshot{
        boosters_json:
          Snapshot.encode_boosters([
            %{collation_id: 100_046, count: 0},
            %{collation_id: 100_052, count: 4}
          ])
      }

      lookup = lookup_fn(%{100_046 => "BLB", 100_052 => "DFT"})

      assert PendingPacks.summarize(snapshot, lookup) ==
               [%{set_code: "DFT", count: 4}]
    end

    test "returns [] when boosters_json is nil (pre-spike-18 snapshot)" do
      snapshot = %Snapshot{boosters_json: nil}
      assert PendingPacks.summarize(snapshot, lookup_fn(%{})) == []
    end

    test "returns [] for nil snapshot" do
      assert PendingPacks.summarize(nil, lookup_fn(%{})) == []
    end
  end

  describe "total/1" do
    test "sums counts across all rows" do
      rows = [
        %{set_code: "DFT", count: 7},
        %{set_code: "BLB", count: 3},
        %{set_code: nil, count: 1}
      ]

      assert PendingPacks.total(rows) == 11
    end

    test "returns 0 for empty list" do
      assert PendingPacks.total([]) == 0
    end
  end
end
