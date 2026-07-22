defmodule Scry2.NetDecking.Sources.LocalJsonSourceTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Sources.LocalJsonSource

  @fixture Path.expand("../../../fixtures/netdecking/local_feed.json", __DIR__)

  test "declares its provenance name" do
    assert LocalJsonSource.source_name() == "local"
  end

  test "reads the feed file into raw_deck maps (deck facts only; identity is the source's)" do
    [deck | _] = LocalJsonSource.fetch(path: @fixture)

    assert deck.name == "Mono-Red Aggro"
    assert deck.archetype == "Aggro"
    assert deck.source_url == "https://example.invalid/mono-red"
    assert deck.decklist_text =~ "Roaring Furnace"
    refute Map.has_key?(deck, :source_name)
  end

  test "carries an explicit per-deck format when the feed provides one" do
    decks = LocalJsonSource.fetch(path: @fixture)
    modern_deck = Enum.find(decks, &(&1.name != "Mono-Red Aggro"))

    assert modern_deck.format == "Modern"
  end

  test "omits format when the feed doesn't provide one (IngestDecklist defaults it)" do
    [deck | _] = LocalJsonSource.fetch(path: @fixture)
    refute Map.has_key?(deck, :format)
  end

  test "missing file yields an empty list (degrades, never crashes)" do
    assert LocalJsonSource.fetch(path: "/no/such/feed.json") == []
  end

  test "nil path yields an empty list" do
    assert LocalJsonSource.fetch(path: nil) == []
  end
end
