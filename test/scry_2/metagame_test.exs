defmodule Scry2.MetagameTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory

  alias Scry2.Metagame
  alias Scry2.Metagame.{ArchetypeDefinition, Classification}

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

  describe "classification over arena_ids" do
    setup do
      Metagame.replace_definitions!("Standard", %{
        definitions: [
          %{
            key: "URProwess",
            kind: "archetype",
            name: "Prowess",
            include_color_in_name: true,
            conditions: [%{"type" => "InMainboard", "cards" => ["Boomerang Basics"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      })

      basics = create_card(%{name: "Boomerang Basics", color_identity: "U"})
      swiftspear = create_card(%{name: "Monastery Swiftspear", color_identity: "R"})

      land =
        create_card(%{
          name: "Riverpyre Verge",
          color_identity: "UR",
          is_land: true,
          types: "Land"
        })

      %{basics: basics, swiftspear: swiftspear, land: land}
    end

    test "classify/3 resolves card maps and composes the display name", context do
      main = %{
        "cards" => [
          %{"arena_id" => context.basics.arena_id, "count" => 4},
          %{"arena_id" => context.swiftspear.arena_id, "count" => 4},
          %{"arena_id" => context.land.arena_id, "count" => 20}
        ]
      }

      assert %Classification{name: "Izzet Prowess", confidence: :exact} =
               Metagame.classify(main, nil)
    end

    test "classify/3 ignores unresolvable arena_ids" do
      main = %{"cards" => [%{"arena_id" => 999_999_999, "count" => 4}]}
      assert Metagame.classify(main, nil) == :unknown
    end

    test "classify/3 handles nil and empty card lists" do
      assert Metagame.classify(nil, nil) == :unknown
      assert Metagame.classify(%{"cards" => []}, %{"cards" => []}) == :unknown
    end

    test "classify_observed/2 classifies partial information with confidence", context do
      observed = [
        %{arena_id: context.basics.arena_id, count: 1},
        %{arena_id: context.swiftspear.arena_id, count: 1}
      ]

      assert %Classification{name: "Izzet Prowess", confidence: :confirmed} =
               Metagame.classify_observed(observed)
    end

    test "classify_observed/2 is :unknown for nothing observed" do
      assert Metagame.classify_observed([]) == :unknown
    end
  end
end
