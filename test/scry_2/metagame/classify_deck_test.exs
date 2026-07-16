defmodule Scry2.Metagame.ClassifyDeckTest do
  use ExUnit.Case, async: true

  alias Scry2.Metagame.{Classification, ClassifyDeck, Definitions}

  # ── Test helpers ────────────────────────────────────────────────────

  defp entry(name, opts \\ []) do
    %{
      name: name,
      count: Keyword.get(opts, :count, 4),
      colors: Keyword.get(opts, :colors, ""),
      land?: Keyword.get(opts, :land?, false)
    }
  end

  defp archetype(name, conditions, opts \\ []) do
    %{
      key: Keyword.get(opts, :key, name),
      name: name,
      include_color_in_name: Keyword.get(opts, :include_color_in_name, false),
      conditions: conditions,
      variants: Keyword.get(opts, :variants, []),
      common_cards: []
    }
  end

  defp fallback(name, common_cards, opts \\ []) do
    %{
      key: Keyword.get(opts, :key, name),
      name: name,
      include_color_in_name: Keyword.get(opts, :include_color_in_name, false),
      conditions: [],
      variants: [],
      common_cards: common_cards
    }
  end

  defp condition(type, cards), do: %{"type" => type, "cards" => cards}

  defp definitions(opts) do
    struct!(Definitions, Keyword.put_new(opts, :format, "Standard"))
  end

  # ── Condition types ─────────────────────────────────────────────────

  describe "condition types" do
    test "InMainboard requires the card in the mainboard" do
      defs = definitions(archetypes: [archetype("A", [condition("InMainboard", ["Card X"])])])

      assert %Classification{archetype: "A"} = ClassifyDeck.run([entry("Card X")], [], defs)
      assert ClassifyDeck.run([], [entry("Card X")], defs) == :unknown
    end

    test "InSideboard requires the card in the sideboard" do
      defs = definitions(archetypes: [archetype("A", [condition("InSideboard", ["Card X"])])])

      assert %Classification{archetype: "A"} = ClassifyDeck.run([], [entry("Card X")], defs)
      assert ClassifyDeck.run([entry("Card X")], [], defs) == :unknown
    end

    test "InMainOrSideboard accepts either board" do
      defs =
        definitions(archetypes: [archetype("A", [condition("InMainOrSideboard", ["Card X"])])])

      assert %Classification{} = ClassifyDeck.run([entry("Card X")], [], defs)
      assert %Classification{} = ClassifyDeck.run([], [entry("Card X")], defs)
      assert ClassifyDeck.run([entry("Other")], [], defs) == :unknown
    end

    test "OneOrMoreInMainboard matches any listed card" do
      defs =
        definitions(
          archetypes: [archetype("A", [condition("OneOrMoreInMainboard", ["Card X", "Card Y"])])]
        )

      assert %Classification{} = ClassifyDeck.run([entry("Card Y")], [], defs)
      assert ClassifyDeck.run([], [entry("Card Y")], defs) == :unknown
    end

    test "OneOrMoreInSideboard matches any listed card in the sideboard" do
      defs =
        definitions(
          archetypes: [archetype("A", [condition("OneOrMoreInSideboard", ["Card X", "Card Y"])])]
        )

      assert %Classification{} = ClassifyDeck.run([], [entry("Card X")], defs)
      assert ClassifyDeck.run([entry("Card X")], [], defs) == :unknown
    end

    test "OneOrMoreInMainOrSideboard matches across boards" do
      defs =
        definitions(
          archetypes: [
            archetype("A", [condition("OneOrMoreInMainOrSideboard", ["Card X", "Card Y"])])
          ]
        )

      assert %Classification{} = ClassifyDeck.run([], [entry("Card Y")], defs)
      assert ClassifyDeck.run([entry("Other")], [entry("Another")], defs) == :unknown
    end

    test "TwoOrMoreInMainboard counts distinct names, not copies" do
      defs =
        definitions(
          archetypes: [
            archetype("A", [condition("TwoOrMoreInMainboard", ["Card X", "Card Y", "Card Z"])])
          ]
        )

      assert %Classification{} = ClassifyDeck.run([entry("Card X"), entry("Card Z")], [], defs)
      assert ClassifyDeck.run([entry("Card X", count: 4)], [], defs) == :unknown
    end

    test "TwoOrMoreInSideboard counts distinct names in the sideboard" do
      defs =
        definitions(
          archetypes: [archetype("A", [condition("TwoOrMoreInSideboard", ["Card X", "Card Y"])])]
        )

      assert %Classification{} = ClassifyDeck.run([], [entry("Card X"), entry("Card Y")], defs)
      assert ClassifyDeck.run([], [entry("Card X")], defs) == :unknown
    end

    test "TwoOrMoreInMainOrSideboard counts a name on both boards twice" do
      defs =
        definitions(
          archetypes: [
            archetype("A", [condition("TwoOrMoreInMainOrSideboard", ["Card X", "Card Y"])])
          ]
        )

      assert %Classification{} = ClassifyDeck.run([entry("Card X")], [entry("Card X")], defs)
      assert ClassifyDeck.run([entry("Card X")], [], defs) == :unknown
    end

    test "DoesNotContain fails when the card is anywhere" do
      defs =
        definitions(
          archetypes: [
            archetype("A", [
              condition("InMainboard", ["Card X"]),
              condition("DoesNotContain", ["Banned Card"])
            ])
          ]
        )

      assert %Classification{} = ClassifyDeck.run([entry("Card X")], [], defs)
      assert ClassifyDeck.run([entry("Card X"), entry("Banned Card")], [], defs) == :unknown
      assert ClassifyDeck.run([entry("Card X")], [entry("Banned Card")], defs) == :unknown
    end

    test "DoesNotContainMainboard only checks the mainboard" do
      defs =
        definitions(
          archetypes: [
            archetype("A", [
              condition("InMainOrSideboard", ["Card X"]),
              condition("DoesNotContainMainboard", ["Card X"])
            ])
          ]
        )

      assert %Classification{} = ClassifyDeck.run([], [entry("Card X")], defs)
      assert ClassifyDeck.run([entry("Card X")], [], defs) == :unknown
    end

    test "DoesNotContainSideboard only checks the sideboard" do
      defs =
        definitions(
          archetypes: [
            archetype("A", [
              condition("InMainOrSideboard", ["Card X"]),
              condition("DoesNotContainSideboard", ["Card X"])
            ])
          ]
        )

      assert %Classification{} = ClassifyDeck.run([entry("Card X")], [], defs)
      assert ClassifyDeck.run([], [entry("Card X")], defs) == :unknown
    end
  end

  # ── Variants ────────────────────────────────────────────────────────

  describe "variants" do
    test "a matching variant refines the base archetype" do
      variant = %{
        "name" => "Special Build",
        "include_color_in_name" => false,
        "conditions" => [condition("InMainboard", ["Signature Card"])]
      }

      defs =
        definitions(
          archetypes: [
            archetype("Base", [condition("InMainboard", ["Core Card"])], variants: [variant])
          ]
        )

      result = ClassifyDeck.run([entry("Core Card"), entry("Signature Card")], [], defs)
      assert %Classification{archetype: "Base", variant: "Special Build"} = result
      assert result.name == "Special Build"

      result = ClassifyDeck.run([entry("Core Card")], [], defs)
      assert %Classification{archetype: "Base", variant: nil, name: "Base"} = result
    end
  end

  # ── Conflicts ───────────────────────────────────────────────────────

  describe "conflicts" do
    test "when several archetypes match, the one with fewer conditions wins" do
      defs =
        definitions(
          archetypes: [
            archetype("Complex", [
              condition("InMainboard", ["Card X"]),
              condition("InMainboard", ["Card Y"])
            ]),
            archetype("Simple", [condition("InMainboard", ["Card X"])])
          ]
        )

      assert %Classification{archetype: "Simple"} =
               ClassifyDeck.run([entry("Card X"), entry("Card Y")], [], defs)
    end
  end

  # ── Fallbacks ───────────────────────────────────────────────────────

  describe "fallbacks" do
    test "used only when no archetype matches, best overlap wins" do
      defs =
        definitions(
          archetypes: [archetype("A", [condition("InMainboard", ["Not Present"])])],
          fallbacks: [
            fallback("Aggro", ["Fast One", "Fast Two"]),
            fallback("Control", ["Slow One"])
          ]
        )

      result = ClassifyDeck.run([entry("Fast One"), entry("Fast Two"), entry("Other")], [], defs)
      assert %Classification{archetype: "Aggro", fallback?: true, confidence: :exact} = result
    end

    test "similarity at or below 0.1 yields :unknown" do
      defs = definitions(fallbacks: [fallback("Aggro", ["Fast One"])])

      # weight 4 / 10 entries = 0.4 → match; weight 1 / 10 = 0.1 → not > 0.1 → unknown
      filler = for index <- 1..9, do: entry("Filler #{index}")

      assert %Classification{} =
               ClassifyDeck.run([entry("Fast One", count: 4) | filler], [], defs)

      assert ClassifyDeck.run([entry("Fast One", count: 1) | filler], [], defs) == :unknown
    end

    test "weight ties break toward the shorter common-cards list" do
      defs =
        definitions(
          fallbacks: [
            fallback("Broad", ["Card X", "Card Y", "Card Z"]),
            fallback("Narrow", ["Card X"])
          ]
        )

      assert %Classification{archetype: "Narrow"} = ClassifyDeck.run([entry("Card X")], [], defs)
    end
  end

  # ── Colors and naming ───────────────────────────────────────────────

  describe "color naming" do
    test "IncludeColorInName composes the color combo with the archetype name" do
      defs =
        definitions(
          archetypes: [
            archetype("Prowess", [condition("InMainboard", ["Stormchaser's Talent"])],
              include_color_in_name: true
            )
          ]
        )

      mainboard = [
        entry("Stormchaser's Talent", colors: "U"),
        entry("Monastery Swiftspear", colors: "R"),
        entry("Steam Vents", colors: "UR", land?: true)
      ]

      assert %Classification{name: "Izzet Prowess", color: "UR"} =
               ClassifyDeck.run(mainboard, [], defs)
    end

    test "a color counts only when present in both lands and nonlands" do
      defs =
        definitions(
          archetypes: [
            archetype("Aggro", [condition("InMainboard", ["Hired Claw"])],
              include_color_in_name: true
            )
          ]
        )

      # White appears only in lands (splash land), green only in nonlands.
      mainboard = [
        entry("Hired Claw", colors: "R"),
        entry("Sylvan Stowaway", colors: "G"),
        entry("Mountain", colors: "R", land?: true),
        entry("Plains", colors: "W", land?: true)
      ]

      assert %Classification{name: "Mono-Red Aggro", color: "R"} =
               ClassifyDeck.run(mainboard, [], defs)
    end

    test "color overrides replace card colors for detection" do
      defs =
        definitions(
          archetypes: [
            archetype("Domain", [condition("InMainboard", ["Leyline Binding"])],
              include_color_in_name: true
            )
          ],
          land_overrides: %{"Spire of Industry" => "WUBRG"}
        )

      mainboard = [
        entry("Leyline Binding", colors: "W"),
        entry("Herd Migration", colors: "G"),
        entry("Zur, Eternal Schemer", colors: "WUB"),
        entry("Etali, Primal Conqueror", colors: "RG"),
        entry("Spire of Industry", colors: "", land?: true)
      ]

      assert %Classification{name: "5-Color Domain", color: "WUBRG"} =
               ClassifyDeck.run(mainboard, [], defs)
    end

    test "colorless composition keeps the bare name" do
      defs =
        definitions(
          archetypes: [
            archetype("Affinity", [condition("InMainboard", ["Ornithopter"])],
              include_color_in_name: true
            )
          ]
        )

      assert %Classification{name: "Affinity", color: ""} =
               ClassifyDeck.run([entry("Ornithopter", colors: "")], [], defs)
    end
  end

  test "empty deck is :unknown" do
    defs = definitions(archetypes: [], fallbacks: [])
    assert ClassifyDeck.run([], [], defs) == :unknown
  end
end
