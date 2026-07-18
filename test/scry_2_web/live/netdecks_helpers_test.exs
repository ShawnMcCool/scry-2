defmodule Scry2Web.NetdecksHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.NetdecksHelpers

  test "format_cost renders non-zero rarities compactly" do
    assert NetdecksHelpers.format_cost(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) == "2u 1r"
    assert NetdecksHelpers.format_cost(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == "—"
    assert NetdecksHelpers.format_cost(%{common: 1, uncommon: 0, rare: 0, mythic: 3}) == "1c 3m"
  end

  test "format_owned_pct renders a whole-percent string" do
    assert NetdecksHelpers.format_owned_pct(1.0) == "100%"
    assert NetdecksHelpers.format_owned_pct(0.82) == "82%"
  end

  test "match_search? matches the group label and variant deck fields case-insensitively" do
    group = %{
      label: "Izzet Prowess",
      variants: [%{deck: %{name: "Challenge 32 — pilot", archetype: "UR Prowess"}}]
    }

    assert NetdecksHelpers.match_search?(group, "izzet")
    assert NetdecksHelpers.match_search?(group, "challenge")
    assert NetdecksHelpers.match_search?(group, "ur prowess")
    refute NetdecksHelpers.match_search?(group, "domain")
    assert NetdecksHelpers.match_search?(group, "")
  end

  test "source_site_url links browsable sources and nothing else" do
    assert NetdecksHelpers.source_site_url("mtgo") == "https://www.mtgo.com/decklists"
    assert NetdecksHelpers.source_site_url("manual") == nil
    assert NetdecksHelpers.source_site_url("local_json") == nil
  end

  test "source_archetype_note shows the source string only when it differs from the title" do
    assert NetdecksHelpers.source_archetype_note(%{archetype: "Prowess"}, "Izzet Prowess") ==
             "Prowess"

    assert NetdecksHelpers.source_archetype_note(%{archetype: "Izzet Prowess"}, "Izzet Prowess") ==
             nil

    assert NetdecksHelpers.source_archetype_note(%{archetype: nil}, "Izzet Prowess") == nil
  end

  test "find_group locates an archetype group by slug across tiers" do
    prowess = %{slug: "izzet-prowess"}
    domain = %{slug: "domain-overlords"}
    catalog = %{buildable: [prowess], craftable: [], short: [domain]}

    assert NetdecksHelpers.find_group(catalog, "domain-overlords") == domain
    assert NetdecksHelpers.find_group(catalog, "izzet-prowess") == prowess
    assert NetdecksHelpers.find_group(catalog, "unknown") == nil
  end

  test "tally_parts lists non-zero statuses in buildable → craftable → short order" do
    assert NetdecksHelpers.tally_parts(%{buildable: 1, craftable: 0, short: 3}) ==
             [{:buildable, 1}, {:short, 3}]

    assert NetdecksHelpers.tally_parts(%{buildable: 0, craftable: 0, short: 0}) == []
  end

  test "wildcard_balances orders the pool common → mythic" do
    assert NetdecksHelpers.wildcard_balances(%{common: 214, uncommon: 180, rare: 12, mythic: 3}) ==
             [{:common, 214}, {:uncommon, 180}, {:rare, 12}, {:mythic, 3}]
  end

  test "cheapest_variant is the variant with the lowest wildcard sort key" do
    cheap = %{result: %{sort_key: {0, 1, 0, 0, 1}}}
    dear = %{result: %{sort_key: {2, 4, 0, 0, 6}}}

    assert NetdecksHelpers.cheapest_variant(%{variants: [dear, cheap]}) == cheap
  end

  test "medal_tone crowns 1st gold, podium silver, everything ranked neutral" do
    assert NetdecksHelpers.medal_tone("1st") == :gold
    assert NetdecksHelpers.medal_tone("2nd") == :silver
    assert NetdecksHelpers.medal_tone("3rd") == :silver
    assert NetdecksHelpers.medal_tone("8th") == :neutral
    assert NetdecksHelpers.medal_tone("14th of 42") == :neutral
    assert NetdecksHelpers.medal_tone(nil) == nil
  end

  describe "ownership_count_entry/1" do
    # The count entry feeding the deck view's gutter rail / badge pill
    # (UIDR-015): counts never cover the card; ownership carries the tone.

    defp entry_for(rows, card), do: NetdecksHelpers.ownership_count_entry(rows).(card)

    test "fully-owned single copies render nothing — blank means one" do
      rows = %{1 => %{name: "Opt", free?: false, needed: 1, owned: 1, missing: 0}}

      assert entry_for(rows, %{arena_id: 1, count: 1}) == nil
    end

    test "fully-owned piles render the count in the owned tone" do
      rows = %{1 => %{name: "Opt", free?: false, needed: 4, owned: 4, missing: 0}}

      assert %{label: "4", class: "text-success"} = entry_for(rows, %{arena_id: 1, count: 4})
    end

    test "missing cards always show their count, warning-toned, with the ownership tooltip" do
      rows = %{1 => %{name: "Namor", free?: false, needed: 1, owned: 0, missing: 1}}

      assert %{label: "1", class: "text-warning", title: "Namor — 0/1 owned"} =
               entry_for(rows, %{arena_id: 1, count: 1})
    end

    test "partially-owned piles show the count in the partial tone" do
      rows = %{1 => %{name: "Bolt", free?: false, needed: 4, owned: 2, missing: 2}}

      assert %{label: "4", class: "text-base-content/60"} =
               entry_for(rows, %{arena_id: 1, count: 4})
    end

    test "basic lands render dimmed with the basic-land tooltip" do
      rows = %{1 => %{name: "Mountain", free?: true, needed: 18, owned: 0, missing: 0}}

      assert %{label: "18", class: "text-base-content/30", title: "Mountain — basic land"} =
               entry_for(rows, %{arena_id: 1, count: 18})
    end

    test "cards without an ownership row fall back to the plain count" do
      assert entry_for(%{}, %{arena_id: 9, count: 1}) == nil
      assert %{label: "3", class: nil, title: nil} = entry_for(%{}, %{arena_id: 9, count: 3})
    end
  end

  describe "sole_variant_deck_id/1" do
    test "returns the deck id when the archetype has exactly one variant" do
      group = %{variants: [%{deck: %{id: 42}}]}
      assert NetdecksHelpers.sole_variant_deck_id(group) == 42
    end

    test "returns nil when the archetype has multiple variants" do
      group = %{variants: [%{deck: %{id: 1}}, %{deck: %{id: 2}}]}
      assert NetdecksHelpers.sole_variant_deck_id(group) == nil
    end

    test "returns nil when there are no variants" do
      assert NetdecksHelpers.sole_variant_deck_id(%{variants: []}) == nil
    end
  end

  describe "delta_sections/3" do
    test "groups deltas by broad card type in canonical order, additions before cuts" do
      cards = %{
        1 => %{name: "Eddymurk Crab", types: "Creature"},
        2 => %{name: "Opt", types: "Instant"},
        3 => %{name: "Island", types: "Basic Land"},
        4 => %{name: "Stormchaser's Talent", types: "Enchantment"}
      }

      deltas = [
        %{arena_id: 3, delta: 1},
        %{arena_id: 2, delta: -2},
        %{arena_id: 1, delta: 2},
        %{arena_id: 4, delta: 3}
      ]

      assert NetdecksHelpers.delta_sections(deltas, cards, %{}) == [
               {"Creatures",
                [%{arena_id: 1, delta: 2, name: "Eddymurk Crab", rarity: nil, missing: 0}]},
               {"Instants & Sorceries",
                [%{arena_id: 2, delta: -2, name: "Opt", rarity: nil, missing: 0}]},
               {"Artifacts & Enchantments",
                [%{arena_id: 4, delta: 3, name: "Stormchaser's Talent", rarity: nil, missing: 0}]},
               {"Lands", [%{arena_id: 3, delta: 1, name: "Island", rarity: nil, missing: 0}]}
             ]
    end

    test "orders additions before cuts inside a section" do
      cards = %{
        1 => %{name: "Alpha", types: "Creature"},
        2 => %{name: "Beta", types: "Creature"},
        3 => %{name: "Gamma", types: "Creature"}
      }

      deltas = [
        %{arena_id: 1, delta: -1},
        %{arena_id: 2, delta: 2},
        %{arena_id: 3, delta: 1}
      ]

      assert [{"Creatures", entries}] = NetdecksHelpers.delta_sections(deltas, cards, %{})
      assert Enum.map(entries, & &1.delta) == [2, 1, -1]
    end

    test "carries each card's rarity and its craft-missing count" do
      cards = %{
        1 => %{name: "Bolt", types: "Instant", rarity: "rare"},
        2 => %{name: "Bear", types: "Creature", rarity: "uncommon"}
      }

      deltas = [%{arena_id: 1, delta: 2}, %{arena_id: 2, delta: 1}]
      # Short two Bolts; the Bear is fully owned (absent from the craft map).
      craft = %{1 => 2}

      entries =
        deltas
        |> NetdecksHelpers.delta_sections(cards, craft)
        |> Enum.flat_map(&elem(&1, 1))

      bolt = Enum.find(entries, &(&1.arena_id == 1))
      bear = Enum.find(entries, &(&1.arena_id == 2))

      assert bolt.rarity == "rare"
      assert bolt.missing == 2
      assert bear.rarity == "uncommon"
      assert bear.missing == 0
    end

    test "empty deltas yield no sections" do
      assert NetdecksHelpers.delta_sections([], %{}, %{}) == []
    end
  end

  test "medal_text compacts a finish to its ordinal" do
    assert NetdecksHelpers.medal_text("1st") == "1st"
    assert NetdecksHelpers.medal_text("14th of 42") == "14th"
    assert NetdecksHelpers.medal_text(nil) == nil
  end

  test "status_order leads with buildable, then craftable, then short" do
    assert NetdecksHelpers.status_order() == [:buildable, :craftable, :short]
  end

  test "status_meta returns presentation metadata per status" do
    for status <- [:buildable, :craftable, :short] do
      meta = NetdecksHelpers.status_meta(status)
      assert is_binary(meta.label)
      assert is_binary(meta.section)
      assert is_binary(meta.badge)
      assert is_binary(meta.icon)
    end

    assert NetdecksHelpers.status_meta(:buildable).section == "Buildable now"
    assert NetdecksHelpers.status_meta(:short).section == "Within reach"
  end

  test "status_meta states each tier's definition and ordering rule (UIDR-017)" do
    assert NetdecksHelpers.status_meta(:buildable).definition =~ "fully owned"
    assert NetdecksHelpers.status_meta(:buildable).ordering == "ordered by best finish"
    assert NetdecksHelpers.status_meta(:craftable).ordering == "ordered by cheapest build"
    assert NetdecksHelpers.status_meta(:short).ordering == "ordered by cheapest build"
  end

  test "cost_pips returns non-zero rarities as {rarity, count} in common→mythic order" do
    assert NetdecksHelpers.cost_pips(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) ==
             [{:uncommon, 2}, {:rare, 1}]

    assert NetdecksHelpers.cost_pips(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == []
  end

  test "any_cost? reflects whether a cost map has non-zero rarities" do
    assert NetdecksHelpers.any_cost?(%{common: 0, uncommon: 0, rare: 1, mythic: 0})
    refute NetdecksHelpers.any_cost?(%{common: 0, uncommon: 0, rare: 0, mythic: 0})
  end

  test "rows_by_arena_id indexes main and sideboard rows by arena_id" do
    main_rows = [
      %{arena_id: 1, name: "Lightning Bolt", needed: 4, owned: 4, missing: 0, free?: false},
      %{arena_id: 2, name: "Mountain", needed: 20, owned: 0, missing: 0, free?: true}
    ]

    side_rows = [
      %{arena_id: 3, name: "Negate", needed: 2, owned: 0, missing: 2, free?: false}
    ]

    lookup = NetdecksHelpers.rows_by_arena_id(main_rows, side_rows)

    assert map_size(lookup) == 3
    assert lookup[1].name == "Lightning Bolt"
    assert lookup[3].missing == 2
  end

  test "rows_by_arena_id skips rows without a resolved arena_id" do
    main_rows = [%{arena_id: nil, name: "Unknown", needed: 1, owned: 0, missing: 1, free?: false}]

    assert NetdecksHelpers.rows_by_arena_id(main_rows, []) == %{}
  end

  test "missing_row_class tints rows with unowned copies" do
    assert NetdecksHelpers.missing_row_class(%{missing: 2}) == "text-warning"
    assert NetdecksHelpers.missing_row_class(%{missing: 0}) == nil
    assert NetdecksHelpers.missing_row_class(nil) == nil
  end

  test "ownership_title describes a row's ownership for tooltips" do
    assert NetdecksHelpers.ownership_title(nil) == nil

    assert NetdecksHelpers.ownership_title(%{
             name: "Mountain",
             free?: true,
             owned: 0,
             needed: 20
           }) == "Mountain — basic land"

    assert NetdecksHelpers.ownership_title(%{
             name: "Lightning Bolt",
             free?: false,
             owned: 2,
             needed: 4
           }) == "Lightning Bolt — 2/4 owned"
  end

  test "card_row_state classifies a decklist row" do
    assert NetdecksHelpers.card_row_state(%{free?: true, owned: 0, missing: 0}) == :free
    assert NetdecksHelpers.card_row_state(%{free?: false, owned: 4, missing: 0}) == :owned
    assert NetdecksHelpers.card_row_state(%{free?: false, owned: 0, missing: 4}) == :missing
    assert NetdecksHelpers.card_row_state(%{free?: false, owned: 2, missing: 2}) == :partial
  end

  test "card_row_tone maps each state to a colour class" do
    for state <- [:free, :owned, :missing, :partial] do
      assert is_binary(NetdecksHelpers.card_row_tone(state))
    end

    assert NetdecksHelpers.card_row_tone(:owned) == "text-success"
    assert NetdecksHelpers.card_row_tone(:missing) == "text-warning"
  end

  test "unresolved_count counts unresolved references on a deck" do
    assert NetdecksHelpers.unresolved_count(%{unresolved_cards: %{"cards" => [%{}, %{}]}}) == 2
    assert NetdecksHelpers.unresolved_count(%{unresolved_cards: %{"cards" => []}}) == 0
    assert NetdecksHelpers.unresolved_count(%{unresolved_cards: nil}) == 0
  end

  test "tile_subtitle joins finish, event, and short date; nil without provenance" do
    provenance = %{
      finish: "1st",
      event_name: "Standard Challenge 32",
      event_date: ~D[2026-06-26]
    }

    assert NetdecksHelpers.tile_subtitle(provenance) ==
             "1st \u00b7 Standard Challenge 32 \u00b7 Jun 26"

    assert NetdecksHelpers.tile_subtitle(nil) == nil
  end

  test "tile_subtitle omits absent parts without dangling separators" do
    assert NetdecksHelpers.tile_subtitle(%{finish: "1st", event_name: nil, event_date: nil}) ==
             "1st"
  end

  test "detail_provenance composes pilot, finish, event, long date, and record" do
    detail = %{
      deck: %{
        pilot: "Venom01",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-06-26]
      },
      finish: "1st",
      record: "7-2"
    }

    assert NetdecksHelpers.detail_provenance(detail) ==
             "Venom01 \u2014 1st \u00b7 Standard Challenge 32 \u00b7 Jun 26, 2026 \u00b7 7-2"
  end

  test "detail_provenance renders partial data and nil when there is none" do
    assert NetdecksHelpers.detail_provenance(%{
             deck: %{pilot: nil, event_name: "Standard League", event_date: nil},
             finish: nil,
             record: nil
           }) == "Standard League"

    assert NetdecksHelpers.detail_provenance(%{
             deck: %{pilot: nil, event_name: nil, event_date: nil},
             finish: nil,
             record: nil
           }) == nil
  end

  test "fully_owned? is true only at 100% owned" do
    assert NetdecksHelpers.fully_owned?(%{maindeck: %{owned_pct: 1.0}})
    refute NetdecksHelpers.fully_owned?(%{maindeck: %{owned_pct: 0.98}})
  end

  test "source_host strips scheme and www" do
    assert NetdecksHelpers.source_host("https://www.mtgo.com/decklist/x") == "mtgo.com"
    assert NetdecksHelpers.source_host("https://example.org/a") == "example.org"
    assert NetdecksHelpers.source_host(nil) == nil
  end

  describe "browse state" do
    defmodule FakeSource do
      @behaviour Scry2.NetDecking.Source
      @impl true
      def source_name, do: "fake"
      @impl true
      def formats, do: ["standard"]
      @impl true
      def fetch, do: []
    end

    test "browse_source_options describes each browsable module" do
      assert [%{name: "fake", module: FakeSource, formats: ["standard"]}] =
               NetdecksHelpers.browse_source_options([FakeSource])
    end

    test "initial_browse selects the first source and its first format" do
      options = NetdecksHelpers.browse_source_options([FakeSource])
      browse = NetdecksHelpers.initial_browse(options)

      assert browse.source == FakeSource
      assert browse.source_name == "fake"
      assert browse.format == "standard"
      assert browse.events == nil
      refute browse.loading?
      assert browse.selected == MapSet.new()
    end

    test "initial_browse is nil with no browsable sources" do
      assert NetdecksHelpers.initial_browse([]) == nil
    end

    test "toggle_selection adds then removes a url" do
      selected = NetdecksHelpers.toggle_selection(MapSet.new(), "u1")
      assert MapSet.member?(selected, "u1")
      refute NetdecksHelpers.toggle_selection(selected, "u1") |> MapSet.member?("u1")
    end
  end

  describe "import_flash/1" do
    test "summarizes successful imports" do
      results = [{:ok, %{ingested: 30, failed: 0}}, {:ok, %{ingested: 2, failed: 0}}]
      assert NetdecksHelpers.import_flash(results) == "Imported 32 decks from 2 events."
    end

    test "singularizes one deck and one event" do
      assert NetdecksHelpers.import_flash([{:ok, %{ingested: 1, failed: 0}}]) ==
               "Imported 1 deck from 1 event."
    end

    test "mentions failed events" do
      results = [{:ok, %{ingested: 5, failed: 0}}, {:error, :unreachable}]

      assert NetdecksHelpers.import_flash(results) ==
               "Imported 5 decks from 1 event. 1 event failed."
    end

    test "all-failed reads as a failure" do
      assert NetdecksHelpers.import_flash([{:error, :a}, {:error, :b}]) ==
               "Couldn't import — 2 events failed."
    end
  end

  describe "matrix_delta_label/1" do
    test "positive deltas carry a plus sign" do
      assert NetdecksHelpers.matrix_delta_label(2) == "+2"
    end

    test "negative deltas render a true minus sign" do
      assert NetdecksHelpers.matrix_delta_label(-1) == "−1"
    end
  end

  describe "matrix_magnitude_label/1" do
    test "zero renders nothing" do
      assert NetdecksHelpers.matrix_magnitude_label(0) == nil
    end

    test "nonzero renders a plus-minus magnitude" do
      assert NetdecksHelpers.matrix_magnitude_label(14) == "±14"
    end
  end
end
