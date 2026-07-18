defmodule Scry2.Decks.CompositionIdentityTest do
  use ExUnit.Case, async: true

  alias Scry2.Decks.CompositionIdentity

  # A representative-by-arena_id map collapses every printing of a card onto a
  # single canonical arena_id (the card's name identity). Two printings of
  # "Island" (105175, 102727) both map to representative 100.
  @reps %{
    105_175 => 100,
    102_727 => 100,
    67_810 => 200,
    95_072 => 300
  }

  describe "canonical_pairs/2" do
    test "collapses printing-only differences onto the same signature" do
      week3 = [%{"arena_id" => 105_175, "count" => 4}, %{"arena_id" => 67_810, "count" => 4}]

      dragonstorm = [
        %{"arena_id" => 102_727, "count" => 4},
        %{"arena_id" => 67_810, "count" => 4}
      ]

      assert CompositionIdentity.canonical_pairs(week3, @reps) ==
               CompositionIdentity.canonical_pairs(dragonstorm, @reps)
    end

    test "sums counts when two printings of the same card appear in one list" do
      split = [%{"arena_id" => 105_175, "count" => 2}, %{"arena_id" => 102_727, "count" => 2}]
      merged = [%{"arena_id" => 105_175, "count" => 4}]

      assert CompositionIdentity.canonical_pairs(split, @reps) == [{100, 4}]
      assert CompositionIdentity.canonical_pairs(merged, @reps) == [{100, 4}]
    end

    test "genuinely different card lists stay distinct" do
      a = [%{"arena_id" => 105_175, "count" => 4}]
      b = [%{"arena_id" => 95_072, "count" => 4}]

      refute CompositionIdentity.canonical_pairs(a, @reps) ==
               CompositionIdentity.canonical_pairs(b, @reps)
    end

    test "different counts of the same card stay distinct" do
      four = [%{"arena_id" => 105_175, "count" => 4}]
      three = [%{"arena_id" => 105_175, "count" => 3}]

      refute CompositionIdentity.canonical_pairs(four, @reps) ==
               CompositionIdentity.canonical_pairs(three, @reps)
    end

    test "arena_ids absent from the map fall back to themselves" do
      cards = [%{"arena_id" => 999_999, "count" => 2}]
      assert CompositionIdentity.canonical_pairs(cards, @reps) == [{999_999, 2}]
    end

    test "is order-independent" do
      forward = [%{"arena_id" => 67_810, "count" => 4}, %{"arena_id" => 95_072, "count" => 2}]
      reverse = [%{"arena_id" => 95_072, "count" => 2}, %{"arena_id" => 67_810, "count" => 4}]

      assert CompositionIdentity.canonical_pairs(forward, @reps) ==
               CompositionIdentity.canonical_pairs(reverse, @reps)
    end

    test "accepts atom-keyed cards" do
      cards = [%{arena_id: 105_175, count: 4}]
      assert CompositionIdentity.canonical_pairs(cards, @reps) == [{100, 4}]
    end

    test "ignores cards missing arena_id or count" do
      cards = [%{"arena_id" => 105_175}, %{"count" => 4}, %{"arena_id" => 67_810, "count" => 1}]
      assert CompositionIdentity.canonical_pairs(cards, @reps) == [{200, 1}]
    end
  end

  describe "hash/2" do
    test "matches for printing-only differences, differs for real changes" do
      week3 = [%{"arena_id" => 105_175, "count" => 4}, %{"arena_id" => 67_810, "count" => 4}]

      dragonstorm = [
        %{"arena_id" => 102_727, "count" => 4},
        %{"arena_id" => 67_810, "count" => 4}
      ]

      other = [%{"arena_id" => 95_072, "count" => 4}, %{"arena_id" => 67_810, "count" => 4}]

      assert CompositionIdentity.hash(week3, @reps) ==
               CompositionIdentity.hash(dragonstorm, @reps)

      refute CompositionIdentity.hash(week3, @reps) == CompositionIdentity.hash(other, @reps)
    end

    test "returns nil for an empty or unresolvable list" do
      assert CompositionIdentity.hash([], @reps) == nil
      assert CompositionIdentity.hash([%{"count" => 4}], @reps) == nil
    end
  end
end
