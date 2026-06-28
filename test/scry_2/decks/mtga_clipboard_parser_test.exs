defmodule Scry2.Decks.MtgaClipboardParserTest do
  use ExUnit.Case, async: true

  alias Scry2.Decks.MtgaClipboardParser

  test "parses a full deck with maindeck and sideboard sections" do
    text = """
    Deck
    4 Lightning Bolt (M21) 162
    3 Counterspell (MH2) 50

    Sideboard
    2 Negate (ZNR) 56
    """

    assert %{main: main, sideboard: side} = MtgaClipboardParser.parse(text)

    assert main == [
             %{name: "Lightning Bolt", set_code: "M21", collector_number: "162", count: 4},
             %{name: "Counterspell", set_code: "MH2", collector_number: "50", count: 3}
           ]

    assert side == [%{name: "Negate", set_code: "ZNR", collector_number: "56", count: 2}]
  end

  test "parses name-only lines (no set/collector number)" do
    text = "Deck\n7 Mountain\n"

    assert %{main: [%{name: "Mountain", set_code: nil, collector_number: nil, count: 7}]} =
             MtgaClipboardParser.parse(text)
  end

  test "treats lines before any header as maindeck and ignores blanks" do
    text = "4 Llanowar Elves (DOM) 168\n\n\n2 Forest\n"

    assert %{main: main, sideboard: []} = MtgaClipboardParser.parse(text)
    assert length(main) == 2
  end

  test "skips unparseable lines without crashing" do
    text = "Deck\n4 Lightning Bolt (M21) 162\ngarbage line\n// a comment\n"

    assert %{main: [%{name: "Lightning Bolt"}]} = MtgaClipboardParser.parse(text)
  end

  test "handles multi-word names with apostrophes and commas" do
    text = "Deck\n1 Jace, the Mind Sculptor (2X2) 61\n"

    assert %{
             main: [
               %{
                 name: "Jace, the Mind Sculptor",
                 set_code: "2X2",
                 collector_number: "61",
                 count: 1
               }
             ]
           } = MtgaClipboardParser.parse(text)
  end
end
