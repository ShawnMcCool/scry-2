defmodule Scry2.Metagame.ParseDefinitionsTest do
  use ExUnit.Case, async: true

  alias Scry2.Metagame.ParseDefinitions

  @fixtures Path.expand("../../fixtures/metagame", __DIR__)

  describe "archetype/2" do
    test "parses a real archetype file into a definition attrs map" do
      json = File.read!(Path.join(@fixtures, "Archetypes/URProwess.json"))

      assert {:ok, definition} = ParseDefinitions.archetype(json, "URProwess")
      assert definition.key == "URProwess"
      assert definition.kind == "archetype"
      assert definition.name == "Prowess"
      assert definition.include_color_in_name == true

      assert %{"type" => "OneOrMoreInMainboard", "cards" => cards} = hd(definition.conditions)
      assert "Slickshot Show-Off" in cards
      assert definition.variants == []
    end

    test "parses variants" do
      json = File.read!(Path.join(@fixtures, "Archetypes/Tokens.json"))

      assert {:ok, definition} = ParseDefinitions.archetype(json, "Tokens")
      assert [variant] = definition.variants
      assert variant["name"] == "Mono White Caretaker"
      assert variant["include_color_in_name"] == false

      assert [%{"type" => "OneOrMoreInMainboard", "cards" => ["Lay Down Arms" | _]}] =
               variant["conditions"]
    end

    test "normalizes condition type case (live data contains OneorMoreInMainboard)" do
      json = ~s({"Name": "X", "IncludeColorInName": false,
                 "Conditions": [{"Type": "OneorMoreInMainboard", "Cards": ["A"]}]})

      assert {:ok, definition} = ParseDefinitions.archetype(json, "X")
      assert [%{"type" => "OneOrMoreInMainboard"}] = definition.conditions
    end

    test "skips conditions with missing or empty cards" do
      json = ~s({"Name": "X", "IncludeColorInName": false,
                 "Conditions": [{"Type": "InMainboard", "Cards": []},
                                {"Type": "InMainboard"},
                                {"Type": "InMainboard", "Cards": ["A"]}]})

      assert {:ok, definition} = ParseDefinitions.archetype(json, "X")
      assert [%{"type" => "InMainboard", "cards" => ["A"]}] = definition.conditions
    end

    test "rejects unknown condition types" do
      json = ~s({"Name": "X", "IncludeColorInName": false,
                 "Conditions": [{"Type": "SomethingNew", "Cards": ["A"]}]})

      assert {:error, {:unknown_condition_type, "SomethingNew"}} =
               ParseDefinitions.archetype(json, "X")
    end

    test "rejects malformed JSON" do
      assert {:error, _reason} = ParseDefinitions.archetype("{nope", "X")
    end

    test "tolerates trailing commas (upstream validates with Newtonsoft, which allows them)" do
      json = ~s({"Name": "X", "IncludeColorInName": false,
                 "Conditions": [{"Type": "InMainboard", "Cards": ["A"],}],})

      assert {:ok, %{name: "X"}} = ParseDefinitions.archetype(json, "X")
    end

    test "parses every vendored seed file" do
      seed_dir = Path.expand("../../../priv/metagame/Formats/Standard", __DIR__)

      for subdir <- ["Archetypes", "Fallbacks"],
          file <- File.ls!(Path.join(seed_dir, subdir)) do
        json = File.read!(Path.join([seed_dir, subdir, file]))

        parse =
          if subdir == "Archetypes",
            do: &ParseDefinitions.archetype/2,
            else: &ParseDefinitions.fallback/2

        assert {:ok, _definition} = parse.(json, Path.rootname(file)),
               "failed to parse #{subdir}/#{file}"
      end
    end
  end

  describe "fallback/2" do
    test "parses a real fallback file" do
      json = File.read!(Path.join(@fixtures, "Fallbacks/Aggro.json"))

      assert {:ok, definition} = ParseDefinitions.fallback(json, "Aggro")
      assert definition.kind == "fallback"
      assert definition.name == "Aggro"
      assert definition.include_color_in_name == true
      assert "Monastery Swiftspear" in definition.common_cards
      assert definition.conditions == []
    end
  end

  describe "color_overrides/1" do
    test "parses the real overrides file with null NonLands" do
      json = File.read!(Path.join(@fixtures, "color_overrides.json"))

      assert {:ok, overrides} = ParseDefinitions.color_overrides(json)
      assert [%{card_name: "Spire of Industry", land: true, colors: "WUBRG"}] = overrides
    end
  end

  describe "rows_from_files/1" do
    test "builds definition and override attrs from a Standard-folder file map" do
      files = %{
        "Archetypes/URProwess.json" =>
          File.read!(Path.join(@fixtures, "Archetypes/URProwess.json")),
        "Archetypes/Broken.json" => "{nope",
        "Fallbacks/Aggro.json" => File.read!(Path.join(@fixtures, "Fallbacks/Aggro.json")),
        "color_overrides.json" => File.read!(Path.join(@fixtures, "color_overrides.json"))
      }

      assert %{definitions: definitions, overrides: overrides, errors: errors} =
               ParseDefinitions.rows_from_files(files)

      assert Enum.map(definitions, & &1.key) |> Enum.sort() == ["Aggro", "URProwess"]
      assert [%{card_name: "Spire of Industry"}] = overrides
      assert [{"Archetypes/Broken.json", _reason}] = errors
    end
  end
end
