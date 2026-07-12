defmodule Scry2.NetDecking.VariantMatrixTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2.NetDecking.VariantMatrix

  # Card reference fixtures. Bolt exists under two printings (two arena_ids,
  # one name) — the matrix must treat them as one card (name identity).
  @bolt 101
  @bolt_reprint 102
  @negate 201
  @duress 301
  @island 401
  @forest 402
  @unresolved 999

  defp cards_by_arena_id do
    %{
      @bolt => build_card(arena_id: @bolt, name: "Lightning Bolt", rarity: "uncommon"),
      @bolt_reprint =>
        build_card(arena_id: @bolt_reprint, name: "Lightning Bolt", rarity: "uncommon"),
      @negate => build_card(arena_id: @negate, name: "Negate", rarity: "common"),
      @duress => build_card(arena_id: @duress, name: "Duress", rarity: "common"),
      @island => build_card(arena_id: @island, name: "Island", rarity: "common", is_land: true),
      @forest => build_card(arena_id: @forest, name: "Forest", rarity: "common", is_land: true)
    }
  end

  defp viewed_deck do
    build_netdeck(
      id: 1,
      main_deck: netdeck_cards([{@bolt, 4}, {@negate, 2}, {@island, 20}]),
      sideboard: netdeck_cards([{@duress, 2}])
    )
  end

  test "cells are copy deltas by name relative to the viewed deck" do
    variant =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt, 3}, {@negate, 2}, {@duress, 2}, {@island, 20}])
      )

    %{columns: [column]} =
      VariantMatrix.build(viewed_deck(), [viewed_deck(), variant], cards_by_arena_id())

    assert column.deltas == %{"Lightning Bolt" => -1, "Duress" => 2}
  end

  test "a card owned under a different printing is not a delta" do
    variant =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt_reprint, 4}, {@negate, 2}, {@island, 20}])
      )

    %{rows: rows, columns: [column]} =
      VariantMatrix.build(viewed_deck(), [variant], cards_by_arena_id())

    assert column.deltas == %{}
    assert rows == []
  end

  test "rows sort most contested first with the viewed deck's copy counts" do
    # Negate differs in two variants, Duress in one.
    variant_a =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt, 4}, {@negate, 4}, {@duress, 1}, {@island, 20}])
      )

    variant_b =
      build_netdeck(
        id: 3,
        main_deck: netdeck_cards([{@bolt, 4}, {@island, 20}])
      )

    %{rows: rows} =
      VariantMatrix.build(viewed_deck(), [variant_a, variant_b], cards_by_arena_id())

    assert Enum.map(rows, & &1.name) == ["Negate", "Duress"]
    assert Enum.map(rows, & &1.contested_count) == [2, 1]
    assert Enum.map(rows, & &1.you_count) == [2, 0]
    assert Enum.map(rows, & &1.rarity) == ["common", "common"]
  end

  test "the viewed deck is excluded from columns and column order is preserved" do
    variant_a =
      build_netdeck(id: 2, main_deck: netdeck_cards([{@bolt, 4}, {@negate, 2}, {@island, 20}]))

    variant_b =
      build_netdeck(id: 3, main_deck: netdeck_cards([{@bolt, 4}, {@negate, 2}, {@island, 20}]))

    %{columns: columns} =
      VariantMatrix.build(
        viewed_deck(),
        [variant_b, viewed_deck(), variant_a],
        cards_by_arena_id()
      )

    assert Enum.map(columns, & &1.deck.id) == [3, 2]
  end

  test "land changes aggregate to a magnitude and never appear as rows" do
    variant =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt, 4}, {@negate, 2}, {@island, 17}, {@forest, 3}])
      )

    %{rows: rows, columns: [column]} =
      VariantMatrix.build(viewed_deck(), [variant], cards_by_arena_id())

    assert rows == []
    assert column.deltas == %{}
    assert column.lands_changed == 6
  end

  test "sideboard changes aggregate to a magnitude" do
    variant =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt, 4}, {@negate, 2}, {@island, 20}]),
        sideboard: netdeck_cards([{@duress, 1}, {@negate, 2}])
      )

    %{columns: [column]} = VariantMatrix.build(viewed_deck(), [variant], cards_by_arena_id())

    assert column.sideboard_changed == 3
  end

  test "total combines spell, land, and sideboard magnitudes" do
    variant =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt, 2}, {@negate, 2}, {@island, 19}, {@forest, 1}]),
        sideboard: netdeck_cards([{@duress, 3}])
      )

    %{columns: [column]} = VariantMatrix.build(viewed_deck(), [variant], cards_by_arena_id())

    assert column.deltas == %{"Lightning Bolt" => -2}
    assert column.lands_changed == 2
    assert column.sideboard_changed == 1
    assert column.total_changed == 5
  end

  test "unresolved arena_ids are excluded everywhere" do
    variant =
      build_netdeck(
        id: 2,
        main_deck: netdeck_cards([{@bolt, 4}, {@negate, 2}, {@island, 20}, {@unresolved, 4}]),
        sideboard: netdeck_cards([{@duress, 2}, {@unresolved, 2}])
      )

    %{rows: rows, columns: [column]} =
      VariantMatrix.build(viewed_deck(), [variant], cards_by_arena_id())

    assert rows == []
    assert column.deltas == %{}
    assert column.lands_changed == 0
    assert column.sideboard_changed == 0
    assert column.total_changed == 0
  end

  test "an identical variant yields an empty column with zero total" do
    twin =
      build_netdeck(
        id: 2,
        main_deck: viewed_deck().main_deck,
        sideboard: viewed_deck().sideboard
      )

    %{columns: [column]} = VariantMatrix.build(viewed_deck(), [twin], cards_by_arena_id())

    assert column.deltas == %{}
    assert column.total_changed == 0
  end
end
