defmodule Scry2.Metagame.ClassifyDeck do
  @moduledoc """
  Pure archetype classification engine — a faithful port of
  MTGOArchetypeParser's detection semantics over MTGOFormatData rules.
  No DB, no side effects.

  Input → output contract: card entries (`%{name, count, colors,
  land?}`) for mainboard and sideboard, plus a loaded
  `Definitions` struct → `Classification` or `:unknown`.

  Detection order:

  1. Every archetype whose conditions all hold matches; a matching
     variant refines its archetype. Conflicts resolve to the match with
     the fewest conditions (the reference parser's "prefer simpler").
  2. When nothing matches, fallbacks ("goodstuff" archetypes) score by
     summed counts of entries appearing in their common-card lists; the
     best must exceed 0.1 similarity (weight / total entries), ties
     breaking toward the shorter list.
  3. Deck color is the set of colors present in **both** lands and
     nonlands (kills splash-land false positives), with per-card
     overrides applied. `IncludeColorInName` prepends the
     `ColorName` ("Izzet Prowess").
  """

  alias Scry2.Metagame.{Classification, ColorName, Definitions}

  @wubrg ~w(W U B R G)

  @type entry :: %{
          name: String.t(),
          count: pos_integer(),
          colors: String.t(),
          land?: boolean()
        }

  @doc "Classify a complete decklist."
  @spec run([entry()], [entry()], Definitions.t()) :: Classification.t() | :unknown
  def run(mainboard, sideboard, %Definitions{} = definitions) do
    color = deck_color(mainboard ++ sideboard, definitions)
    main_names = MapSet.new(mainboard, & &1.name)
    side_names = MapSet.new(sideboard, & &1.name)

    matches =
      definitions.archetypes
      |> Enum.filter(&conditions_hold?(&1.conditions, main_names, side_names))
      |> Enum.flat_map(fn rule ->
        case matching_variants(rule, main_names, side_names) do
          [] -> [{rule, nil}]
          variants -> Enum.map(variants, &{rule, &1})
        end
      end)

    case matches do
      [] -> best_fallback(mainboard ++ sideboard, definitions, color)
      matches -> matches |> Enum.min_by(&complexity/1) |> to_classification(color, :exact)
    end
  end

  # ── Condition evaluation ────────────────────────────────────────────

  defp conditions_hold?(conditions, main_names, side_names) do
    Enum.all?(conditions, &condition_holds?(&1, main_names, side_names))
  end

  defp condition_holds?(%{"type" => "InMainboard", "cards" => [card | _]}, main, _side),
    do: MapSet.member?(main, card)

  defp condition_holds?(%{"type" => "InSideboard", "cards" => [card | _]}, _main, side),
    do: MapSet.member?(side, card)

  defp condition_holds?(%{"type" => "InMainOrSideboard", "cards" => [card | _]}, main, side),
    do: MapSet.member?(main, card) or MapSet.member?(side, card)

  defp condition_holds?(%{"type" => "OneOrMoreInMainboard", "cards" => cards}, main, _side),
    do: Enum.any?(cards, &MapSet.member?(main, &1))

  defp condition_holds?(%{"type" => "OneOrMoreInSideboard", "cards" => cards}, _main, side),
    do: Enum.any?(cards, &MapSet.member?(side, &1))

  defp condition_holds?(%{"type" => "OneOrMoreInMainOrSideboard", "cards" => cards}, main, side),
    do: Enum.any?(cards, &(MapSet.member?(main, &1) or MapSet.member?(side, &1)))

  defp condition_holds?(%{"type" => "TwoOrMoreInMainboard", "cards" => cards}, main, _side),
    do: distinct_matches(cards, main) >= 2

  defp condition_holds?(%{"type" => "TwoOrMoreInSideboard", "cards" => cards}, _main, side),
    do: distinct_matches(cards, side) >= 2

  defp condition_holds?(%{"type" => "TwoOrMoreInMainOrSideboard", "cards" => cards}, main, side),
    do: distinct_matches(cards, main) + distinct_matches(cards, side) >= 2

  defp condition_holds?(%{"type" => "DoesNotContain", "cards" => [card | _]}, main, side),
    do: not MapSet.member?(main, card) and not MapSet.member?(side, card)

  defp condition_holds?(
         %{"type" => "DoesNotContainMainboard", "cards" => [card | _]},
         main,
         _side
       ),
       do: not MapSet.member?(main, card)

  defp condition_holds?(
         %{"type" => "DoesNotContainSideboard", "cards" => [card | _]},
         _main,
         side
       ),
       do: not MapSet.member?(side, card)

  defp distinct_matches(cards, names) do
    cards |> Enum.uniq() |> Enum.count(&MapSet.member?(names, &1))
  end

  # ── Variants and conflicts ──────────────────────────────────────────

  defp matching_variants(rule, main_names, side_names) do
    Enum.filter(rule.variants, fn variant ->
      conditions_hold?(variant["conditions"], main_names, side_names)
    end)
  end

  defp complexity({rule, nil}), do: length(rule.conditions)
  defp complexity({rule, variant}), do: length(rule.conditions) + length(variant["conditions"])

  # ── Fallbacks ───────────────────────────────────────────────────────

  defp best_fallback([], _definitions, _color), do: :unknown

  defp best_fallback(entries, %Definitions{fallbacks: fallbacks}, color) do
    scored =
      fallbacks
      |> Enum.map(fn rule -> {rule, fallback_weight(rule, entries)} end)
      |> Enum.reject(fn {_rule, weight} -> weight == 0 end)

    with [_ | _] <- scored,
         {rule, weight} = best_scored(scored),
         true <- weight / length(entries) > 0.1 do
      to_classification({rule, nil}, color, :exact, fallback?: true)
    else
      _no_qualifying_fallback -> :unknown
    end
  end

  defp fallback_weight(rule, entries) do
    common = MapSet.new(rule.common_cards)

    entries
    |> Enum.filter(&MapSet.member?(common, &1.name))
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  defp best_scored(scored) do
    {_rule, max_weight} = Enum.max_by(scored, fn {_rule, weight} -> weight end)

    scored
    |> Enum.filter(fn {_rule, weight} -> weight == max_weight end)
    |> Enum.min_by(fn {rule, _weight} -> length(rule.common_cards) end)
  end

  # ── Colors and naming ───────────────────────────────────────────────

  defp deck_color(entries, definitions) do
    land_colors = colors_seen(entries, definitions.land_overrides, & &1.land?)
    nonland_colors = colors_seen(entries, definitions.nonland_overrides, &(not &1.land?))

    @wubrg
    |> Enum.filter(&(MapSet.member?(land_colors, &1) and MapSet.member?(nonland_colors, &1)))
    |> Enum.join()
  end

  defp colors_seen(entries, overrides, member?) do
    entries
    |> Enum.flat_map(fn entry ->
      case Map.fetch(overrides, entry.name) do
        {:ok, colors} -> String.graphemes(colors)
        :error -> if member?.(entry), do: String.graphemes(entry.colors || ""), else: []
      end
    end)
    |> MapSet.new()
  end

  defp to_classification({rule, variant}, color, confidence, opts \\ []) do
    archetype_name = compose(rule.name, rule.include_color_in_name, color)

    variant_name =
      case variant do
        nil -> nil
        variant -> compose(variant["name"], variant["include_color_in_name"] == true, color)
      end

    %Classification{
      name: variant_name || archetype_name,
      archetype: archetype_name,
      variant: variant_name,
      fallback?: Keyword.get(opts, :fallback?, false),
      color: color,
      confidence: confidence
    }
  end

  defp compose(name, true, color) when color != "", do: "#{ColorName.name(color)} #{name}"
  defp compose(name, _include_color, _color), do: name
end
