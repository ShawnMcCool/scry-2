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

  test "match_search? matches name and archetype case-insensitively" do
    entry = %{deck: %{name: "Mono-Red Aggro", archetype: "Aggro"}}
    assert NetdecksHelpers.match_search?(entry, "mono")
    assert NetdecksHelpers.match_search?(entry, "aggro")
    refute NetdecksHelpers.match_search?(entry, "control")
    assert NetdecksHelpers.match_search?(entry, "")
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

  test "cost_pips returns non-zero rarities as {rarity, count} in common→mythic order" do
    assert NetdecksHelpers.cost_pips(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) ==
             [{:uncommon, 2}, {:rare, 1}]

    assert NetdecksHelpers.cost_pips(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == []
  end

  test "any_cost? reflects whether a cost map has non-zero rarities" do
    assert NetdecksHelpers.any_cost?(%{common: 0, uncommon: 0, rare: 1, mythic: 0})
    refute NetdecksHelpers.any_cost?(%{common: 0, uncommon: 0, rare: 0, mythic: 0})
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
end
