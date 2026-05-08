defmodule Scry2.Cards.ScryfallTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.Scryfall

  describe "parse_card/1 — set metadata" do
    test "extracts set_name from raw card" do
      raw = %{
        "id" => "abc",
        "name" => "Lightning Bolt",
        "set" => "stx",
        "set_name" => "Strixhaven: School of Mages"
      }

      assert %{set_name: "Strixhaven: School of Mages"} = Scryfall.parse_card(raw)
    end

    test "parses released_at as a Date" do
      raw = %{
        "id" => "abc",
        "name" => "Card",
        "set" => "stx",
        "released_at" => "2021-04-23"
      }

      assert %{released_at: ~D[2021-04-23]} = Scryfall.parse_card(raw)
    end

    test "passes through nil released_at" do
      raw = %{"id" => "abc", "name" => "Card", "set" => "stx"}
      assert %{released_at: nil} = Scryfall.parse_card(raw)
    end

    test "rejects malformed dates as nil" do
      raw = %{
        "id" => "abc",
        "name" => "Card",
        "set" => "stx",
        "released_at" => "not-a-date"
      }

      assert %{released_at: nil} = Scryfall.parse_card(raw)
    end

    test "passes through nil set_name" do
      raw = %{"id" => "abc", "name" => "Card", "set" => "stx"}
      assert %{set_name: nil} = Scryfall.parse_card(raw)
    end
  end
end
