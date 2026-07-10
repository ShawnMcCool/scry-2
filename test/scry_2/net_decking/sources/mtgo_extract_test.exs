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

  test "joins standings, final rank, and win/loss onto each deck by loginid" do
    [first_deck, second_deck] = MtgoExtract.raw_decks(@html, @url)

    assert first_deck.pilot == "1OR513N86"
    assert first_deck.event_name == "Standard Challenge 32"
    assert first_deck.event_date == ~D[2026-06-08]
    assert first_deck.placement == 14
    assert first_deck.swiss_rank == 14
    assert first_deck.field_size == 42
    assert first_deck.wins == 3
    assert first_deck.losses == 2

    assert second_deck.pilot == "Misplacedginger"
    assert second_deck.placement == 25
    assert second_deck.wins == 1
    assert second_deck.losses == 2
  end

  test "a page without a description yields nil event_name, not a fallback" do
    html = ~s"""
    <script>window.MTGO.decklists.data = {
    "decklists": [{"loginid": "1", "player": "solo",
      "main_deck": [{"qty": 4, "card_attributes": {"card_name": "Sear"}}],
      "sideboard_deck": []}]};</script>
    """

    [deck] = MtgoExtract.raw_decks(html, "u")

    assert deck.event_name == nil
    assert deck.name == "MTGO Standard — solo"
  end

  test "decks without standings entries carry nil provenance" do
    html = ~s"""
    <script>window.MTGO.decklists.data = {"description": "Standard League",
    "decklists": [{"loginid": "1", "player": "solo",
      "main_deck": [{"qty": 4, "card_attributes": {"card_name": "Sear"}}],
      "sideboard_deck": []}]};</script>
    """

    [deck] = MtgoExtract.raw_decks(html, "u")

    assert deck.pilot == "solo"
    assert deck.event_name == "Standard League"
    assert deck.event_date == nil
    assert deck.placement == nil
    assert deck.swiss_rank == nil
    assert deck.field_size == nil
    assert deck.wins == nil
    assert deck.losses == nil
  end
end
