defmodule Scry2.MetagameTest do
  use Scry2.DataCase, async: true

  alias Scry2.Metagame
  alias Scry2.Metagame.ArchetypeDefinition

  describe "definitions/1" do
    test "lazily seeds from priv/metagame when the format has no rows" do
      definitions = Metagame.definitions("Standard")

      assert definitions.format == "Standard"
      assert length(definitions.archetypes) > 40
      assert length(definitions.fallbacks) >= 5
      assert definitions.land_overrides["Spire of Industry"] == "WUBRG"

      prowess = Enum.find(definitions.archetypes, &(&1.key == "URProwess"))
      assert prowess.name == "Prowess"
      assert prowess.include_color_in_name == true
      assert Enum.any?(prowess.conditions, &(&1["type"] == "OneOrMoreInMainboard"))

      assert Repo.aggregate(ArchetypeDefinition, :count) > 40
    end

    test "reads existing rows without reseeding" do
      Metagame.definitions("Standard")
      count = Repo.aggregate(ArchetypeDefinition, :count)

      Metagame.definitions("Standard")
      assert Repo.aggregate(ArchetypeDefinition, :count) == count
    end
  end

  describe "replace_definitions!/2" do
    test "returns :unchanged when content matches and :updated when it differs" do
      Metagame.definitions("Standard")

      parsed = %{
        definitions: [
          %{
            key: "OnlyOne",
            kind: "archetype",
            name: "Only One",
            include_color_in_name: false,
            conditions: [%{"type" => "InMainboard", "cards" => ["Some Card"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      }

      assert Metagame.replace_definitions!("Standard", parsed) == :updated
      definitions = Metagame.definitions("Standard")
      assert [%{key: "OnlyOne"}] = definitions.archetypes
      assert definitions.fallbacks == []

      assert Metagame.replace_definitions!("Standard", parsed) == :unchanged
    end
  end
end
