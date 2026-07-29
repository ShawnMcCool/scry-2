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

    test "skips structs in a card list" do
      assert DeckList.entries(%{"cards" => [%URI{}, %{"arena_id" => 111, "count" => 4}]}) ==
               [%{arena_id: 111, count: 4}]
    end

    test "parses mixed string- and atom-keyed fields on one card" do
      assert DeckList.entries([%{"arena_id" => 7, :count => 3}]) == [%{arena_id: 7, count: 3}]
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

  # Ported from the deleted printing-insensitive-identity module's test suite
  # (formerly test/scry_2/decks/composition_identity_test.exs) — scenarios not
  # already covered above by canonical_pairs/2 or entries/1. Scenarios that
  # tested the old module's raw-map parsing (accepting string/atom-keyed
  # cards directly, ignoring cards missing arena_id/count, falling back
  # unmapped arena_ids to themselves) are obsolete: that parsing now lives in
  # `entries/1` and is already covered by the "entries/1" describe block
  # above and by "arena_ids absent from the representative map represent
  # themselves" above. The old module's nil-on-empty hash behavior is
  # covered by `test/scry_2/deck_list_golden_test.exs`.
  describe "canonical_pairs/2 — printing-insensitive identity (ported)" do
    @printing_representatives %{
      105_175 => 100,
      102_727 => 100,
      67_810 => 200,
      95_072 => 300
    }

    test "collapses printing-only differences onto the same signature" do
      week3 =
        DeckList.entries([
          %{"arena_id" => 105_175, "count" => 4},
          %{"arena_id" => 67_810, "count" => 4}
        ])

      dragonstorm =
        DeckList.entries([
          %{"arena_id" => 102_727, "count" => 4},
          %{"arena_id" => 67_810, "count" => 4}
        ])

      assert DeckList.canonical_pairs(week3, @printing_representatives) ==
               DeckList.canonical_pairs(dragonstorm, @printing_representatives)
    end

    test "sums counts when two printings of the same card appear in one list" do
      split =
        DeckList.entries([
          %{"arena_id" => 105_175, "count" => 2},
          %{"arena_id" => 102_727, "count" => 2}
        ])

      merged = DeckList.entries([%{"arena_id" => 105_175, "count" => 4}])

      assert DeckList.canonical_pairs(split, @printing_representatives) == [{100, 4}]
      assert DeckList.canonical_pairs(merged, @printing_representatives) == [{100, 4}]
    end

    test "genuinely different card lists stay distinct" do
      a = DeckList.entries([%{"arena_id" => 105_175, "count" => 4}])
      b = DeckList.entries([%{"arena_id" => 95_072, "count" => 4}])

      refute DeckList.canonical_pairs(a, @printing_representatives) ==
               DeckList.canonical_pairs(b, @printing_representatives)
    end

    test "different counts of the same card stay distinct" do
      four = DeckList.entries([%{"arena_id" => 105_175, "count" => 4}])
      three = DeckList.entries([%{"arena_id" => 105_175, "count" => 3}])

      refute DeckList.canonical_pairs(four, @printing_representatives) ==
               DeckList.canonical_pairs(three, @printing_representatives)
    end

    test "is order-independent" do
      forward =
        DeckList.entries([
          %{"arena_id" => 67_810, "count" => 4},
          %{"arena_id" => 95_072, "count" => 2}
        ])

      reverse =
        DeckList.entries([
          %{"arena_id" => 95_072, "count" => 2},
          %{"arena_id" => 67_810, "count" => 4}
        ])

      assert DeckList.canonical_pairs(forward, @printing_representatives) ==
               DeckList.canonical_pairs(reverse, @printing_representatives)
    end

    test "printing-insensitive hash matches for equivalent decks, differs for real changes" do
      week3 =
        DeckList.entries([
          %{"arena_id" => 105_175, "count" => 4},
          %{"arena_id" => 67_810, "count" => 4}
        ])

      dragonstorm =
        DeckList.entries([
          %{"arena_id" => 102_727, "count" => 4},
          %{"arena_id" => 67_810, "count" => 4}
        ])

      other =
        DeckList.entries([
          %{"arena_id" => 95_072, "count" => 4},
          %{"arena_id" => 67_810, "count" => 4}
        ])

      week3_hash =
        week3 |> DeckList.canonical_pairs(@printing_representatives) |> :erlang.phash2()

      dragonstorm_hash =
        dragonstorm |> DeckList.canonical_pairs(@printing_representatives) |> :erlang.phash2()

      other_hash =
        other |> DeckList.canonical_pairs(@printing_representatives) |> :erlang.phash2()

      assert week3_hash == dragonstorm_hash
      refute week3_hash == other_hash
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
