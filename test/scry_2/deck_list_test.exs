defmodule Scry2.DeckListTest do
  use ExUnit.Case, async: true

  alias Scry2.DeckList

  describe "entries/1" do
    test "parses the stored string-keyed map shape" do
      stored = %{
        "cards" => [%{"arena_id" => 111, "count" => 4}, %{"arena_id" => 222, "count" => 2}]
      }

      assert DeckList.entries(stored) == [
               %{arena_id: 111, count: 4},
               %{arena_id: 222, count: 2}
             ]
    end

    test "parses atom-keyed maps and bare card lists" do
      assert DeckList.entries(%{cards: [%{arena_id: 111, count: 4}]}) == [
               %{arena_id: 111, count: 4}
             ]

      assert DeckList.entries([%{"arena_id" => 111, "count" => 4}]) == [
               %{arena_id: 111, count: 4}
             ]
    end

    test "skips malformed cards and non-integer fields" do
      cards = [
        %{"arena_id" => 111, "count" => 4},
        %{"arena_id" => nil, "count" => 4},
        %{"count" => 4},
        %{"arena_id" => "111", "count" => 4},
        %{"arena_id" => 111},
        "not a map"
      ]

      assert DeckList.entries(%{"cards" => cards}) == [%{arena_id: 111, count: 4}]
    end

    test "nil and shapeless input is empty" do
      assert DeckList.entries(nil) == []
      assert DeckList.entries(%{}) == []
      assert DeckList.entries(%{"cards" => "corrupt"}) == []
    end
  end

  describe "identity_key/1" do
    test "downcases and trims" do
      assert DeckList.identity_key("  Fable of the Mirror-Breaker ") ==
               "fable of the mirror-breaker"
    end
  end

  describe "canonical_pairs/2" do
    test "collapses printings onto representatives, sums counts, sorts" do
      entries = [
        %{arena_id: 86_423, count: 4},
        %{arena_id: 77_777, count: 2},
        %{arena_id: 86_423, count: 1},
        %{arena_id: 91_020, count: 24}
      ]

      assert DeckList.canonical_pairs(entries, %{77_777 => 86_423}) ==
               [{86_423, 7}, {91_020, 24}]
    end

    test "arena_ids absent from the representative map represent themselves" do
      assert DeckList.canonical_pairs([%{arena_id: 5, count: 1}], %{}) == [{5, 1}]
    end

    test "empty entries yield empty pairs" do
      assert DeckList.canonical_pairs([], %{1 => 2}) == []
    end
  end

  describe "name_keys/2" do
    test "resolves entries to identity keys, skipping unresolved arena_ids" do
      cards_by_arena_id = %{
        111 => %{name: "Llanowar Elves"},
        222 => %{name: "LLANOWAR ELVES"},
        333 => %{name: nil}
      }

      entries = [
        %{arena_id: 111, count: 4},
        %{arena_id: 222, count: 1},
        %{arena_id: 333, count: 1},
        %{arena_id: 999, count: 1}
      ]

      assert DeckList.name_keys(entries, cards_by_arena_id) ==
               MapSet.new(["llanowar elves"])
    end
  end
end
