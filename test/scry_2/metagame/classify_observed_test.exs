defmodule Scry2.Metagame.ClassifyObservedTest do
  use ExUnit.Case, async: true

  alias Scry2.Metagame.{Classification, ClassifyDeck, Definitions}

  defp entry(name, opts \\ []) do
    %{
      name: name,
      count: Keyword.get(opts, :count, 1),
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
      variants: [],
      common_cards: []
    }
  end

  defp fallback(name, common_cards) do
    %{
      key: name,
      name: name,
      include_color_in_name: false,
      conditions: [],
      variants: [],
      common_cards: common_cards
    }
  end

  defp condition(type, cards), do: %{"type" => type, "cards" => cards}

  defp definitions(opts) do
    struct!(Definitions, Keyword.put_new(opts, :format, "Standard"))
  end

  test "more satisfied inclusion conditions wins" do
    defs =
      definitions(
        archetypes: [
          archetype("One Signal", [condition("InMainboard", ["Card A"])]),
          archetype("Two Signals", [
            condition("InMainboard", ["Card A"]),
            condition("InMainboard", ["Card B"])
          ])
        ]
      )

    assert %Classification{archetype: "Two Signals", confidence: :confirmed} =
             ClassifyDeck.observed([entry("Card A"), entry("Card B"), entry("Card C")], defs)
  end

  test "unsatisfied inclusion conditions are undecided, not failures" do
    defs =
      definitions(
        archetypes: [
          archetype("Deep", [
            condition("InMainboard", ["Card A"]),
            condition("InMainboard", ["Never Seen"])
          ])
        ]
      )

    assert %Classification{archetype: "Deep", confidence: :likely} =
             ClassifyDeck.observed([entry("Card A")], defs)
  end

  test "an observed excluded card disqualifies the archetype" do
    defs =
      definitions(
        archetypes: [
          archetype("Blocked", [
            condition("InMainboard", ["Card A"]),
            condition("InMainboard", ["Card B"]),
            condition("DoesNotContain", ["Poison Pill"])
          ]),
          archetype("Other", [condition("InMainboard", ["Card A"])])
        ]
      )

    observed = [entry("Card A"), entry("Card B"), entry("Poison Pill")]

    assert %Classification{archetype: "Other"} = ClassifyDeck.observed(observed, defs)
  end

  test "main/side-specific conditions collapse to the observed set" do
    defs =
      definitions(
        archetypes: [
          archetype("Sideboard Tech", [condition("InSideboard", ["Tech Card"])])
        ]
      )

    assert %Classification{archetype: "Sideboard Tech"} =
             ClassifyDeck.observed([entry("Tech Card")], defs)
  end

  test "tied best candidates yield :unknown" do
    defs =
      definitions(
        archetypes: [
          archetype("First", [condition("InMainboard", ["Shared Card"])]),
          archetype("Second", [condition("InMainboard", ["Shared Card"])])
        ]
      )

    assert ClassifyDeck.observed([entry("Shared Card")], defs) == :unknown
  end

  test "ties break toward the archetype with fewer total conditions" do
    defs =
      definitions(
        archetypes: [
          archetype("Broad", [
            condition("InMainboard", ["Shared Card"]),
            condition("InMainboard", ["Never Seen"])
          ]),
          archetype("Tight", [condition("InMainboard", ["Shared Card"])])
        ]
      )

    assert %Classification{archetype: "Tight", confidence: :confirmed} =
             ClassifyDeck.observed([entry("Shared Card")], defs)
  end

  test "IncludeColorInName composes from nonland colors when no lands were observed" do
    defs =
      definitions(
        archetypes: [
          archetype("Prowess", [condition("InMainboard", ["Slickshot Show-Off"])],
            include_color_in_name: true
          )
        ]
      )

    observed = [
      entry("Slickshot Show-Off", colors: "R"),
      entry("Stormchaser's Talent", colors: "U")
    ]

    assert %Classification{name: "Izzet Prowess", color: "UR"} =
             ClassifyDeck.observed(observed, defs)
  end

  describe "fallback scoring" do
    test "requires at least 4 distinct observed nonlands and 0.25 overlap" do
      defs = definitions(fallbacks: [fallback("Aggro", ["Fast A", "Fast B", "Fast C", "Fast D"])])

      observed = [
        entry("Fast A"),
        entry("Fast B"),
        entry("Off Plan One"),
        entry("Off Plan Two"),
        entry("Mountain", land?: true)
      ]

      assert %Classification{archetype: "Aggro", fallback?: true, confidence: :likely} =
               ClassifyDeck.observed(observed, defs)
    end

    test "below the distinct-count floor yields :unknown" do
      defs = definitions(fallbacks: [fallback("Aggro", ["Fast A", "Fast B"])])

      assert ClassifyDeck.observed([entry("Fast A"), entry("Fast B")], defs) == :unknown
    end

    test "below the overlap ratio yields :unknown" do
      defs = definitions(fallbacks: [fallback("Aggro", ["Fast A"])])

      observed = [
        entry("Fast A"),
        entry("Off One"),
        entry("Off Two"),
        entry("Off Three"),
        entry("Off Four")
      ]

      assert ClassifyDeck.observed(observed, defs) == :unknown
    end
  end

  test "empty observed set is :unknown" do
    assert ClassifyDeck.observed([], definitions(archetypes: [], fallbacks: [])) == :unknown
  end
end
