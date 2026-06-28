defmodule Scry2.Decks.MtgaClipboardFormatTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.{Card, Set}
  alias Scry2.Decks.Deck
  alias Scry2.Decks.MtgaClipboardFormat

  describe "format_card_lists/3" do
    test "renders main deck and sideboard from raw card-list maps" do
      cards = %{
        100_001 => %Card{
          arena_id: 100_001,
          name: "Lightning Bolt",
          collector_number: "162",
          set: %Set{code: "m21"}
        },
        100_002 => %Card{
          arena_id: 100_002,
          name: "Negate",
          collector_number: "56",
          set: %Set{code: "znr"}
        }
      }

      main_deck = %{"cards" => [%{"arena_id" => 100_001, "count" => 4}]}
      sideboard = %{"cards" => [%{"arena_id" => 100_002, "count" => 2}]}

      text = MtgaClipboardFormat.format_card_lists(main_deck, sideboard, cards)

      assert text == """
             Deck
             4 Lightning Bolt (M21) 162

             Sideboard
             2 Negate (ZNR) 56\
             """
    end

    test "tolerates nil main_deck and sideboard" do
      assert MtgaClipboardFormat.format_card_lists(nil, nil, %{}) == ""
    end
  end

  describe "format/2" do
    test "renders a constructed deck with mainboard and sideboard" do
      cards = %{
        100_001 => %Card{
          arena_id: 100_001,
          name: "Lightning Bolt",
          collector_number: "162",
          set: %Set{code: "m21"}
        },
        100_002 => %Card{
          arena_id: 100_002,
          name: "Counterspell",
          collector_number: "50",
          set: %Set{code: "mh2"}
        },
        100_003 => %Card{
          arena_id: 100_003,
          name: "Negate",
          collector_number: "56",
          set: %Set{code: "znr"}
        }
      }

      deck = %Deck{
        current_main_deck: %{
          "cards" => [
            %{"arena_id" => 100_001, "count" => 4},
            %{"arena_id" => 100_002, "count" => 3}
          ]
        },
        current_sideboard: %{
          "cards" => [%{"arena_id" => 100_003, "count" => 2}]
        }
      }

      text = MtgaClipboardFormat.format(deck, cards)

      assert text == """
             Deck
             4 Lightning Bolt (M21) 162
             3 Counterspell (MH2) 50

             Sideboard
             2 Negate (ZNR) 56\
             """
    end

    test "renders a mainboard-only deck without the Sideboard section" do
      cards = %{
        100_001 => %Card{
          arena_id: 100_001,
          name: "Lightning Bolt",
          collector_number: "162",
          set: %Set{code: "m21"}
        }
      }

      deck = %Deck{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 100_001, "count" => 4}]
        },
        current_sideboard: %{"cards" => []}
      }

      text = MtgaClipboardFormat.format(deck, cards)

      assert text == """
             Deck
             4 Lightning Bolt (M21) 162\
             """

      refute text =~ "Sideboard"
    end

    test "accepts atom-keyed card entries (matches DeckSubmitted payload shape)" do
      cards = %{
        100_001 => %Card{
          arena_id: 100_001,
          name: "Lightning Bolt",
          collector_number: "162",
          set: %Set{code: "m21"}
        }
      }

      deck = %Deck{
        current_main_deck: %{
          "cards" => [%{arena_id: 100_001, count: 4}]
        },
        current_sideboard: %{"cards" => []}
      }

      text = MtgaClipboardFormat.format(deck, cards)
      assert text =~ "4 Lightning Bolt (M21) 162"
    end

    test "falls back to count + name when set/collector_number is unknown" do
      cards = %{
        100_001 => %{arena_id: 100_001, name: "Mystery Card"}
      }

      deck = %Deck{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 100_001, "count" => 4}]
        },
        current_sideboard: %{"cards" => []}
      }

      text = MtgaClipboardFormat.format(deck, cards)

      assert text == """
             Deck
             4 Mystery Card\
             """
    end

    test "emits a count + arena_id placeholder when the card is missing entirely" do
      deck = %Deck{
        current_main_deck: %{
          "cards" => [%{"arena_id" => 999_999, "count" => 2}]
        },
        current_sideboard: %{"cards" => []}
      }

      text = MtgaClipboardFormat.format(deck, %{})

      assert text =~ "2 #999999"
    end

    test "returns an empty string for an empty deck" do
      deck = %Deck{
        current_main_deck: %{"cards" => []},
        current_sideboard: %{"cards" => []}
      }

      assert MtgaClipboardFormat.format(deck, %{}) == ""
    end

    test "tolerates nil main_deck / sideboard maps" do
      deck = %Deck{current_main_deck: nil, current_sideboard: nil}
      assert MtgaClipboardFormat.format(deck, %{}) == ""
    end
  end
end
