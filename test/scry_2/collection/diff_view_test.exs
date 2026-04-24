defmodule Scry2.Collection.DiffViewTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Diff
  alias Scry2.Collection.DiffView

  describe "entries/2" do
    test "joins arena_ids to names and sorts by descending count then ascending arena_id" do
      json = Diff.encode_counts(%{30_001 => 1, 30_002 => 4, 30_003 => 4})

      cards = %{
        30_001 => %{arena_id: 30_001, name: "Lightning Bolt"},
        30_002 => %{arena_id: 30_002, name: "Counterspell"},
        30_003 => %{arena_id: 30_003, name: "Black Lotus"}
      }

      assert DiffView.entries(json, cards) == [
               %{arena_id: 30_002, count: 4, name: "Counterspell"},
               %{arena_id: 30_003, count: 4, name: "Black Lotus"},
               %{arena_id: 30_001, count: 1, name: "Lightning Bolt"}
             ]
    end

    test "unknown arena_ids fall back to #NNNNN (unknown)" do
      json = Diff.encode_counts(%{91_234 => 2})

      assert DiffView.entries(json, %{}) == [
               %{arena_id: 91_234, count: 2, name: "#91234 (unknown)"}
             ]
    end

    test "missing or empty name falls back to unknown rendering" do
      json = Diff.encode_counts(%{30_001 => 1})

      assert DiffView.entries(json, %{30_001 => %{name: ""}}) == [
               %{arena_id: 30_001, count: 1, name: "#30001 (unknown)"}
             ]
    end
  end

  describe "arena_ids/1" do
    test "returns the union of acquired and removed arena_ids" do
      diff = %Diff{
        cards_added_json: Diff.encode_counts(%{30_001 => 1, 30_002 => 2}),
        cards_removed_json: Diff.encode_counts(%{30_002 => 1, 30_003 => 4})
      }

      assert Enum.sort(DiffView.arena_ids(diff)) == [30_001, 30_002, 30_003]
    end

    test "handles empty payloads" do
      diff = %Diff{
        cards_added_json: Diff.encode_counts(%{}),
        cards_removed_json: Diff.encode_counts(%{})
      }

      assert DiffView.arena_ids(diff) == []
    end
  end
end
