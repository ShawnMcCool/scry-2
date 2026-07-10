defmodule Scry2.NetDecking.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Deck
  alias Scry2.NetDecking.Provenance

  describe "finish_label/1" do
    test "playoff placements 1..8 render as absolute ordinals" do
      assert Provenance.finish_label(%Deck{placement: 1}) == "1st"
      assert Provenance.finish_label(%Deck{placement: 2}) == "2nd"
      assert Provenance.finish_label(%Deck{placement: 3}) == "3rd"
      assert Provenance.finish_label(%Deck{placement: 8, field_size: 42}) == "8th"
    end

    test "deeper placements include the field size" do
      assert Provenance.finish_label(%Deck{placement: 14, field_size: 42}) == "14th of 42"
      assert Provenance.finish_label(%Deck{placement: 22, field_size: 42}) == "22nd of 42"
    end

    test "deeper placements without a known field render bare" do
      assert Provenance.finish_label(%Deck{placement: 14}) == "14th"
    end

    test "falls back to swiss rank when there is no placement" do
      assert Provenance.finish_label(%Deck{swiss_rank: 9, field_size: 42}) == "9th of 42"
    end

    test "nil when the deck has no rank data" do
      assert Provenance.finish_label(%Deck{}) == nil
    end
  end

  describe "record_label/1" do
    test "renders wins-losses" do
      assert Provenance.record_label(%Deck{wins: 7, losses: 2}) == "7-2"
    end

    test "nil when either side is missing" do
      assert Provenance.record_label(%Deck{wins: 7}) == nil
      assert Provenance.record_label(%Deck{}) == nil
    end
  end

  describe "best_finish_deck/1" do
    test "picks the deck with the lowest placement" do
      first = %Deck{id: 1, placement: 1}
      deep = %Deck{id: 2, placement: 14}

      assert Provenance.best_finish_deck([deep, first]).id == 1
    end

    test "a placed deck beats a swiss-only deck" do
      placed = %Deck{id: 1, placement: 14}
      swiss_only = %Deck{id: 2, swiss_rank: 2}

      assert Provenance.best_finish_deck([swiss_only, placed]).id == 1
    end

    test "falls back to the best swiss rank" do
      better = %Deck{id: 1, swiss_rank: 5}
      worse = %Deck{id: 2, swiss_rank: 9}

      assert Provenance.best_finish_deck([worse, better]).id == 1
    end

    test "nil when no deck carries rank data" do
      assert Provenance.best_finish_deck([%Deck{id: 1}, %Deck{id: 2}]) == nil
    end
  end

  describe "sort_by_finish/1" do
    test "orders placement first, then swiss, then unranked" do
      placed = %Deck{id: 1, placement: 3}
      swiss = %Deck{id: 2, swiss_rank: 2}
      unranked = %Deck{id: 3}
      winner = %Deck{id: 4, placement: 1}

      assert [4, 1, 2, 3] =
               [placed, swiss, unranked, winner]
               |> Provenance.sort_by_finish()
               |> Enum.map(& &1.id)
    end
  end
end
