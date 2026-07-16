defmodule Scry2.NetDeckingTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory
  alias Scry2.NetDecking

  test "catalog scores decks against the current snapshot and groups by status" do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    _mountain = create_card(name: "Mountain", rarity: "common")

    create_collection_snapshot(
      entries: [{bolt.arena_id, 4}],
      wildcards_common: 0,
      wildcards_uncommon: 0,
      wildcards_rare: 0,
      wildcards_mythic: 0
    )

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Mono-Red",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    catalog = NetDecking.catalog()

    assert [%{deck: deck, result: %{status: :buildable}}] = catalog.buildable
    assert deck.name == "Mono-Red"
    assert catalog.craftable == []
    assert catalog.short == []
  end

  test "catalog with no snapshot returns decks as fully short" do
    _bolt = create_card(name: "Lightning Bolt", rarity: "rare")

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "X",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    catalog = NetDecking.catalog()
    assert [%{result: %{status: :short}}] = catalog.short
  end

  test "deck_detail returns per-card owned/missing rows, balances, and export text" do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    _mountain = create_card(name: "Mountain", rarity: "common")

    create_collection_snapshot(
      entries: [{bolt.arena_id, 2}],
      wildcards_common: 0,
      wildcards_uncommon: 0,
      wildcards_rare: 5,
      wildcards_mythic: 0
    )

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "Mono-Red",
        archetype: "Aggro",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    detail = NetDecking.deck_detail(deck)

    # Own 2 of 4 rare Bolts, 5 rare wildcards on hand → craftable
    assert detail.result.status == :craftable
    assert detail.wildcards.rare == 5

    bolt_row = Enum.find(detail.main_rows, &(&1.arena_id == bolt.arena_id))
    assert bolt_row.needed == 4
    assert bolt_row.owned == 2
    assert bolt_row.missing == 2
    assert bolt_row.rarity == "rare"
    refute bolt_row.free?

    mountain_row = Enum.find(detail.main_rows, &(&1.name == "Mountain"))
    assert mountain_row.free?
    assert mountain_row.missing == 0

    assert detail.export_text =~ "Lightning Bolt"
  end

  test "deck_detail includes the variant matrix for the deck's cluster" do
    _bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    _shock = create_card(name: "Shock", rarity: "common")
    _mountain = create_card(name: "Mountain", rarity: "common", is_land: true, types: "Land")

    {:ok, viewed} =
      NetDecking.import_decklist(%{
        name: "Mono-Red A",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Shock\n16 Mountain\n"
      })

    {:ok, _variant} =
      NetDecking.import_decklist(%{
        name: "Mono-Red B",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n3 Shock\n17 Mountain\n"
      })

    detail = NetDecking.deck_detail(viewed)

    assert [%{name: "Shock", you_count: 4, contested_count: 1}] = detail.matrix.rows
    assert [column] = detail.matrix.columns
    assert column.deck.name == "Mono-Red B"
    assert column.deltas == %{"Shock" => -1}
    assert column.lands_changed == 1
    assert column.total_changed == 2
  end

  test "deck_detail counts a card owned under a different printing as owned" do
    # Two printings of one card share a name; the deck resolves to one, the
    # player owns the other. Name-identity ownership must still count it.
    printing_a = create_card(name: "Roaring Furnace", rarity: "rare")
    printing_b = create_card(name: "Roaring Furnace", rarity: "rare")

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "DFC Test",
        source_name: "manual",
        decklist_text: "Deck\n4 Roaring Furnace\n"
      })

    [%{"arena_id" => resolved_id}] = deck.main_deck["cards"]

    other_id =
      Enum.find([printing_a.arena_id, printing_b.arena_id], &(&1 != resolved_id))

    create_collection_snapshot(entries: [{other_id, 4}])

    detail = NetDecking.deck_detail(deck)
    row = Enum.find(detail.main_rows, &(&1.name == "Roaring Furnace"))

    assert row.owned == 4
    assert row.missing == 0
  end

  test "source_status summarizes decks per source with counts and latest fetch" do
    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "A",
        source_name: "mtgo",
        decklist_text: "Deck\n1 Alpha\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "B",
        source_name: "mtgo",
        decklist_text: "Deck\n1 Beta\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "C",
        source_name: "local",
        decklist_text: "Deck\n1 Gamma\n"
      })

    status = NetDecking.source_status()

    assert [
             %{source_name: "local", count: 1},
             %{source_name: "mtgo", count: 2}
           ] = status

    assert Enum.all?(status, &match?(%DateTime{}, &1.latest))
  end

  test "catalog collapses near-identical decks into one representative with a count" do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_card(name: "Goblin Raider", rarity: "common", color_identity: "R")
    create_card(name: "Shock Bolt", rarity: "common", color_identity: "R")
    create_card(name: "Grizzly Bear", rarity: "rare", color_identity: "G")

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Red A",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Red B",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n1 Grizzly Bear\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Bears",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Grizzly Bear\n"
      })

    catalog = NetDecking.catalog()
    entries = catalog.buildable ++ catalog.craftable ++ catalog.short

    # Red A + Red B share 3/4 nonland cards (Jaccard 0.75 >= 0.7) -> one entry, count 2.
    red = Enum.find(entries, &(&1.variant_count == 2))
    assert red
    assert red.color_identity == "R"
    assert red.label =~ "Mono-Red"
    assert Enum.any?(entries, &(&1.variant_count == 1))
  end

  test "deck_detail falls back to the economy inventory when the collection snapshot has no wildcards" do
    # The fallback scanner captures cards only — wildcards_* stay nil on the
    # collection snapshot. The log-derived economy inventory is then the best
    # available balance.
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")

    create_collection_snapshot(entries: [{bolt.arena_id, 0}])
    create_inventory_snapshot(wildcards_rare: 7, wildcards_mythic: 2)

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "Burn",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    detail = NetDecking.deck_detail(deck)

    assert detail.wildcards.rare == 7
    assert detail.wildcards.mythic == 2
    # 4 rare Bolts owned 0, 7 rare wildcards on hand → craftable
    assert detail.result.status == :craftable
  end

  test "snapshot wildcards win over the economy inventory when present" do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")

    create_collection_snapshot(entries: [{bolt.arena_id, 0}], wildcards_rare: 1)
    create_inventory_snapshot(wildcards_rare: 7)

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "Burn",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    detail = NetDecking.deck_detail(deck)

    assert detail.wildcards.rare == 1
  end

  test "catalog entries carry the cluster's best-finish provenance" do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_card(name: "Goblin Raider", rarity: "common", color_identity: "R")
    create_card(name: "Shock Bolt", rarity: "common", color_identity: "R")
    create_card(name: "Grizzly Bear", rarity: "rare", color_identity: "G")

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Standard Challenge 32 — deep",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n",
        pilot: "deep",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-06-08],
        placement: 14,
        field_size: 42
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Standard Challenge 32 — winner",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n1 Grizzly Bear\n",
        pilot: "winner",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-06-26],
        placement: 1,
        field_size: 42
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Bears",
        source_name: "manual",
        decklist_text: "Deck\n4 Grizzly Bear\n"
      })

    catalog = NetDecking.catalog()
    entries = catalog.buildable ++ catalog.craftable ++ catalog.short

    red = Enum.find(entries, &(&1.variant_count == 2))
    assert red.provenance.finish == "1st"
    assert red.provenance.event_name == "Standard Challenge 32"
    assert red.provenance.event_date == ~D[2026-06-26]

    bears = Enum.find(entries, &(&1.variant_count == 1))
    assert bears.provenance == nil
  end

  test "deck_detail returns the archetype label and the cluster's variants sorted by finish" do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_card(name: "Goblin Raider", rarity: "common", color_identity: "R")
    create_card(name: "Shock Bolt", rarity: "common", color_identity: "R")

    {:ok, deep_deck} =
      NetDecking.import_decklist(%{
        name: "Standard Challenge 32 — deep",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n",
        pilot: "deep",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-06-08],
        placement: 14,
        swiss_rank: 14,
        field_size: 42,
        wins: 3,
        losses: 2
      })

    {:ok, _winner_deck} =
      NetDecking.import_decklist(%{
        name: "Standard Challenge 32 — winner",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n3 Shock Bolt\n",
        pilot: "winner",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-06-26],
        placement: 1,
        field_size: 42,
        wins: 7,
        losses: 2
      })

    detail = NetDecking.deck_detail(deep_deck)

    assert detail.label =~ "Mono-Red"

    assert [first_variant, second_variant] = detail.variants
    assert first_variant.deck.pilot == "winner"
    assert first_variant.finish == "1st"
    assert first_variant.record == "7-2"
    assert second_variant.deck.pilot == "deep"
    assert second_variant.finish == "14th of 42"
    assert %{} = first_variant.wildcard_cost
  end

  test "deck_detail for an unclustered deck lists only itself as a variant" do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "Solo",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    detail = NetDecking.deck_detail(deck)

    assert [%{deck: %{id: variant_id}, finish: nil, record: nil}] = detail.variants
    assert variant_id == deck.id
  end

  describe "archetype classification" do
    defp install_burn_definition do
      Scry2.Metagame.replace_definitions!("Standard", %{
        definitions: [
          %{
            key: "Burn",
            kind: "archetype",
            name: "Burn",
            include_color_in_name: true,
            conditions: [%{"type" => "InMainboard", "cards" => ["Lightning Bolt"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      })
    end

    test "catalog entries and deck_detail title by the classified archetype name" do
      install_burn_definition()
      create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
      create_card(name: "Mountain", rarity: "common", color_identity: "R", is_land: true)

      {:ok, deck} =
        NetDecking.import_decklist(%{
          name: "Standard Challenge 32 — pilot",
          source_name: "mtgo",
          decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
        })

      catalog = NetDecking.catalog()
      entries = catalog.buildable ++ catalog.craftable ++ catalog.short
      assert [%{label: "Mono-Red Burn"}] = entries

      assert NetDecking.deck_detail(deck).label == "Mono-Red Burn"
    end

    test "unclassified decks keep the synthetic color · hero label" do
      create_card(name: "Grizzly Bear", rarity: "rare", color_identity: "G")

      {:ok, deck} =
        NetDecking.import_decklist(%{
          name: "Bears",
          source_name: "manual",
          decklist_text: "Deck\n4 Grizzly Bear\n"
        })

      assert NetDecking.deck_detail(deck).label =~ "Grizzly Bear"
    end

    test "reclassify_archetypes! re-stamps the corpus against current definitions" do
      create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

      {:ok, deck} =
        NetDecking.import_decklist(%{
          name: "Pre-definitions",
          source_name: "manual",
          decklist_text: "Deck\n4 Lightning Bolt\n"
        })

      assert deck.archetype_name == nil

      install_burn_definition()

      assert NetDecking.reclassify_archetypes!() == 1
      assert NetDecking.get_deck(deck.id).archetype_name == "Burn"
    end
  end

  describe "browsable_sources/1" do
    defmodule Browsable do
      @behaviour Scry2.NetDecking.Source
      @impl true
      def source_name, do: "browsable"
      @impl true
      def formats, do: ["standard"]
      @impl true
      def fetch, do: []
    end

    defmodule NotBrowsable do
      @behaviour Scry2.NetDecking.Source
      @impl true
      def source_name, do: "not-browsable"
      @impl true
      def formats, do: []
      @impl true
      def fetch, do: []
    end

    test "keeps only sources that declare at least one format" do
      assert NetDecking.browsable_sources([Browsable, NotBrowsable]) == [Browsable]
    end
  end

  test "imported_source_urls returns the distinct non-nil source urls" do
    create_card(name: "Lightning Bolt")

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "A",
        source_name: "mtgo",
        source_url: "https://example/event-1",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "B",
        source_name: "manual",
        decklist_text: "Deck\n2 Lightning Bolt\n"
      })

    assert NetDecking.imported_source_urls() == MapSet.new(["https://example/event-1"])
  end

  describe "auto-fetch setting" do
    test "defaults to enabled" do
      assert NetDecking.auto_fetch_enabled?("mtgo")
    end

    test "round-trips off and on" do
      NetDecking.set_auto_fetch("mtgo", false)
      refute NetDecking.auto_fetch_enabled?("mtgo")

      NetDecking.set_auto_fetch("mtgo", true)
      assert NetDecking.auto_fetch_enabled?("mtgo")
    end
  end
end
