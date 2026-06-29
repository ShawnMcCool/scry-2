defmodule Scry2.NetDecking.Sources.LocalJsonSourceTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Sources.LocalJsonSource

  @fixture Path.expand("../../../fixtures/netdecking/local_feed.json", __DIR__)

  test "reads the feed file into raw_deck maps" do
    [deck | _] = LocalJsonSource.fetch(path: @fixture)

    assert deck.name == "Mono-Red Aggro"
    assert deck.source_name == "local"
    assert deck.archetype == "Aggro"
    assert deck.source_url == "https://example.invalid/mono-red"
    assert deck.decklist_text =~ "Roaring Furnace"
  end

  test "missing file yields an empty list (degrades, never crashes)" do
    assert LocalJsonSource.fetch(path: "/no/such/feed.json") == []
  end

  test "nil path yields an empty list" do
    assert LocalJsonSource.fetch(path: nil) == []
  end
end
