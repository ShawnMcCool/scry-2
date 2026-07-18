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

  describe "parse_card/1 — printing treatments" do
    test "extracts the treatment fields that drive basic-printing ranking" do
      raw = %{
        "id" => "abc",
        "name" => "Spirebluff Canal",
        "set" => "om1",
        "promo" => true,
        "full_art" => true,
        "variation" => true,
        "frame_effects" => ["showcase", "extendedart"],
        "border_color" => "borderless"
      }

      assert %{
               promo: true,
               full_art: true,
               variation: true,
               frame_effects: "showcase extendedart",
               border_color: "borderless"
             } = Scryfall.parse_card(raw)
    end

    test "treatment fields default to unremarkable when absent" do
      raw = %{"id" => "abc", "name" => "Card", "set" => "stx"}

      assert %{
               promo: false,
               full_art: false,
               variation: false,
               frame_effects: "",
               border_color: nil
             } = Scryfall.parse_card(raw)
    end
  end

  describe "parse_card/1 — image_uris" do
    test "keeps top-level image_uris when present" do
      raw = %{
        "id" => "abc",
        "name" => "Card",
        "set" => "stx",
        "image_uris" => %{"normal" => "https://img/normal.jpg"}
      }

      assert %{image_uris: %{"normal" => "https://img/normal.jpg"}} = Scryfall.parse_card(raw)
    end

    test "falls back to the front face's image_uris on double-faced layouts" do
      raw = %{
        "id" => "abc",
        "name" => "Fable of the Mirror-Breaker // Reflection of Kiki-Jiki",
        "set" => "neo",
        "card_faces" => [
          %{"image_uris" => %{"normal" => "https://img/front.jpg"}},
          %{"image_uris" => %{"normal" => "https://img/back.jpg"}}
        ]
      }

      assert %{image_uris: %{"normal" => "https://img/front.jpg"}} = Scryfall.parse_card(raw)
    end
  end
end
