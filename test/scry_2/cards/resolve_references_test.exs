defmodule Scry2.Cards.ResolveReferencesTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory
  alias Scry2.Cards

  test "resolves by (set_code, collector_number) exactly" do
    set = create_set(code: "TST")

    card =
      create_card(name: "Lightning Bolt", rarity: "rare", collector_number: "162", set_id: set.id)

    refs = [%{name: "WRONG NAME", set_code: "TST", collector_number: "162", count: 4}]

    assert %{resolved: [%{arena_id: arena_id, count: 4}], unresolved: []} =
             Cards.resolve_references(refs)

    assert arena_id == card.arena_id
  end

  test "falls back to case-insensitive name when set/collector absent" do
    card = create_card(name: "Negate", rarity: "common")

    refs = [%{name: "negate", set_code: nil, collector_number: nil, count: 2}]

    assert %{resolved: [%{arena_id: arena_id, count: 2}], unresolved: []} =
             Cards.resolve_references(refs)

    assert arena_id == card.arena_id
  end

  test "reports unresolved references, keeps resolved ones" do
    card = create_card(name: "Forest", rarity: "common")

    refs = [
      %{name: "Forest", set_code: nil, collector_number: nil, count: 7},
      %{name: "Nonexistent Card", set_code: "ZZZ", collector_number: "999", count: 1}
    ]

    assert %{resolved: [%{arena_id: arena_id, count: 7}], unresolved: [unresolved]} =
             Cards.resolve_references(refs)

    assert arena_id == card.arena_id
    assert unresolved.name == "Nonexistent Card"
  end
end
