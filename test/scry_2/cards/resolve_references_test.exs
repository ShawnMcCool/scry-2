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

  # Universes Beyond "Universes Within" cards (e.g. OM1 "Through the
  # Omenpaths") carry the Magic-flavored name in the MTGA client DB while
  # Scryfall names them after the licensed IP. Synthesis keeps the Scryfall
  # name on `cards_cards`, so a decklist that uses the MTGA/MTGO name resolves
  # only through the mirror alias.
  test "resolves via MTGA mirror name when cards_cards uses the other naming convention" do
    card = create_card(name: "Spectacular Spider-Man", rarity: "rare", arena_id: 104_661)
    create_mtga_card(arena_id: 104_661, name: "Ademi of the Silkchutes")

    refs = [%{name: "Ademi of the Silkchutes", set_code: nil, collector_number: nil, count: 3}]

    assert %{resolved: [%{arena_id: arena_id, count: 3}], unresolved: []} =
             Cards.resolve_references(refs)

    assert arena_id == card.arena_id
  end

  test "resolves via Scryfall mirror name alias" do
    card = create_card(name: "Ademi of the Silkchutes", rarity: "rare", arena_id: 104_662)
    create_scryfall_card(arena_id: 104_662, name: "Spectacular Spider-Man")

    refs = [%{name: "Spectacular Spider-Man", set_code: nil, collector_number: nil, count: 1}]

    assert %{resolved: [%{arena_id: arena_id, count: 1}], unresolved: []} =
             Cards.resolve_references(refs)

    assert arena_id == card.arena_id
  end

  # The MTGA client DB wraps some words in <nobr> layout tags
  # ("<nobr>Fire-Brained</nobr> Scheme"). The decklist name is clean, so the
  # alias must strip the tags before matching.
  test "resolves via MTGA mirror name after stripping <nobr> layout tags" do
    card = create_card(name: "Some Licensed Name", rarity: "rare", arena_id: 104_729)
    create_mtga_card(arena_id: 104_729, name: "<nobr>Fire-Brained</nobr> Scheme")

    refs = [%{name: "Fire-Brained Scheme", set_code: nil, collector_number: nil, count: 2}]

    assert %{resolved: [%{arena_id: arena_id, count: 2}], unresolved: []} =
             Cards.resolve_references(refs)

    assert arena_id == card.arena_id
  end

  test "mirror alias only resolves to arena_ids present in cards_cards" do
    # Mirror knows the name, but no synthesised card exists for it — must stay
    # unresolved rather than resolving to a phantom arena_id.
    create_mtga_card(arena_id: 104_663, name: "Zora, Spider Fancier")

    refs = [%{name: "Zora, Spider Fancier", set_code: nil, collector_number: nil, count: 2}]

    assert %{resolved: [], unresolved: [unresolved]} = Cards.resolve_references(refs)
    assert unresolved.name == "Zora, Spider Fancier"
  end
end
