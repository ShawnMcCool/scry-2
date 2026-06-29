defmodule Scry2.NetDecking.Sources.MtgoExtractTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Sources.MtgoExtract

  @html File.read!(
          Path.expand("../../../fixtures/netdecking/mtgo_standard_challenge.html", __DIR__)
        )

  @url "https://www.mtgo.com/decklist/standard-challenge-32-2026-06-0812843830"

  test "extracts raw_decks from window.MTGO.decklists.data" do
    decks = MtgoExtract.raw_decks(@html, @url)

    assert length(decks) == 2
    deck = hd(decks)

    assert deck.source_name == "mtgo"
    assert deck.source_url == @url
    assert deck.name =~ "Standard Challenge 32"
    # quantity + card name lines, e.g. "1 Thundering Falls"
    assert deck.decklist_text =~ ~r/^\d+ \S.*/m
    assert deck.decklist_text =~ "Deck"
    assert deck.decklist_text =~ "Sideboard"
  end

  test "html without the data assignment yields []" do
    assert MtgoExtract.raw_decks("<html>nope</html>", "u") == []
  end
end
