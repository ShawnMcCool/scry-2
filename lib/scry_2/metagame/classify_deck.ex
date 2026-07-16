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

  `observed/2` is the partial-information mode (our extension, for
  opponent decks): inclusion conditions count toward a match when
  satisfied by the observed cards and are undecided otherwise;
  exclusions disqualify only when the excluded card was actually seen.
  Results grade as `:confirmed`/`:likely` instead of `:exact` — see
  `Classification`.
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

  @observed_fallback_min_distinct 4
  @observed_fallback_min_overlap 0.25

  @doc """
  Classify from partial information — the cards observed from an
  opponent during a match, with no main/side split.
  """
  @spec observed([entry()], Definitions.t()) :: Classification.t() | :unknown
  def observed([], _definitions), do: :unknown

  def observed(entries, %Definitions{} = definitions) do
    color = observed_color(entries, definitions)
    names = MapSet.new(entries, & &1.name)

    candidates =
      definitions.archetypes
      |> Enum.map(&score_candidate(&1, names))
      |> Enum.reject(&is_nil/1)

    case best_candidate(candidates) do
      {rule, satisfied, total_inclusions} ->
        confidence = if satisfied == total_inclusions, do: :confirmed, else: :likely
        to_classification({rule, nil}, color, confidence)

      :ambiguous ->
        :unknown

      :none ->
        observed_fallback(entries, definitions, color)
    end
  end

  # ── Partial-information scoring ─────────────────────────────────────

  # nil when disqualified by an observed exclusion or nothing satisfied;
  # otherwise {rule, satisfied_inclusions, total_inclusions}.
  defp score_candidate(rule, names) do
    {inclusions, exclusions} = Enum.split_with(rule.conditions, &inclusion?/1)

    if Enum.any?(exclusions, &exclusion_violated?(&1, names)) do
      nil
    else
      case Enum.count(inclusions, &inclusion_satisfied?(&1, names)) do
        0 -> nil
        satisfied -> {rule, satisfied, length(inclusions)}
      end
    end
  end

  defp inclusion?(%{"type" => type}), do: not String.starts_with?(type, "DoesNotContain")

  defp exclusion_violated?(%{"cards" => [card | _]}, names), do: MapSet.member?(names, card)

  # Board designations collapse for observed cards: a card seen on the
  # battlefield satisfies both mainboard and sideboard conditions.
  defp inclusion_satisfied?(%{"type" => type, "cards" => cards}, names) do
    cond do
      String.starts_with?(type, "TwoOrMore") -> distinct_matches(cards, names) >= 2
      String.starts_with?(type, "OneOrMore") -> Enum.any?(cards, &MapSet.member?(names, &1))
      true -> MapSet.member?(names, hd(cards))
    end
  end

  defp best_candidate([]), do: :none

  defp best_candidate(candidates) do
    case Enum.sort_by(candidates, &candidate_rank/1) do
      [best] ->
        best

      [best, runner_up | _rest] ->
        if candidate_rank(best) == candidate_rank(runner_up), do: :ambiguous, else: best
    end
  end

  defp candidate_rank({rule, satisfied, _total_inclusions}),
    do: {-satisfied, length(rule.conditions)}

  defp observed_fallback(entries, %Definitions{fallbacks: fallbacks}, color) do
    observed_nonlands = entries |> Enum.reject(& &1.land?) |> Enum.uniq_by(& &1.name)

    scored =
      fallbacks
      |> Enum.map(fn rule ->
        common = MapSet.new(rule.common_cards)
        {rule, Enum.count(observed_nonlands, &MapSet.member?(common, &1.name))}
      end)
      |> Enum.reject(fn {_rule, matched} -> matched == 0 end)

    with true <- length(observed_nonlands) >= @observed_fallback_min_distinct,
         [_ | _] <- scored,
         {rule, matched} = best_scored(scored),
         true <- matched / length(observed_nonlands) >= @observed_fallback_min_overlap do
      to_classification({rule, nil}, color, :likely, fallback?: true)
    else
      _below_threshold -> :unknown
    end
  end

  defp observed_color(entries, definitions) do
    land_colors = colors_seen(entries, definitions.land_overrides, & &1.land?)
    nonland_colors = colors_seen(entries, definitions.nonland_overrides, &(not &1.land?))

    seen =
      if MapSet.size(land_colors) == 0 do
        nonland_colors
      else
        MapSet.intersection(land_colors, nonland_colors)
      end

    @wubrg |> Enum.filter(&MapSet.member?(seen, &1)) |> Enum.join()
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
