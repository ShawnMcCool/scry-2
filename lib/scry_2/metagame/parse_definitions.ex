defmodule Scry2.Metagame.ParseDefinitions do
  @moduledoc """
  Raw MTGOFormatData JSON → definition row attrs. Pure functions, no DB.

  Input → output contract:

  - `archetype/2` — one `Archetypes/*.json` file body → attrs map for an
    `ArchetypeDefinition` row (`kind: "archetype"`).
  - `fallback/2` — one `Fallbacks/*.json` file body → attrs map
    (`kind: "fallback"`, cards under `common_cards`).
  - `color_overrides/1` — the format's `color_overrides.json` body →
    list of `ColorOverride` row attrs.
  - `rows_from_files/1` — a `%{relative_path => content}` map covering a
    whole format folder → `%{definitions, overrides, errors}`, skipping
    malformed files into `errors` instead of failing the batch.

  Condition types are normalized case-insensitively to the canonical
  MTGOArchetypeParser spelling (the live data contains at least one
  `"OneorMoreInMainboard"` typo). Conditions without cards are skipped,
  matching the reference implementation. Unknown condition types reject
  the whole file — misclassifying silently is worse than skipping.
  """

  @condition_types [
    "InMainboard",
    "InSideboard",
    "InMainOrSideboard",
    "OneOrMoreInMainboard",
    "OneOrMoreInSideboard",
    "OneOrMoreInMainOrSideboard",
    "TwoOrMoreInMainboard",
    "TwoOrMoreInSideboard",
    "TwoOrMoreInMainOrSideboard",
    "DoesNotContain",
    "DoesNotContainMainboard",
    "DoesNotContainSideboard"
  ]

  @canonical_by_downcase Map.new(@condition_types, &{String.downcase(&1), &1})

  @type definition_attrs :: %{
          key: String.t(),
          kind: String.t(),
          name: String.t(),
          include_color_in_name: boolean(),
          conditions: [map()],
          variants: [map()],
          common_cards: [String.t()]
        }

  @type override_attrs :: %{card_name: String.t(), land: boolean(), colors: String.t()}

  @spec archetype(String.t(), String.t()) :: {:ok, definition_attrs()} | {:error, term()}
  def archetype(json, key) do
    with {:ok, data} <- decode(json),
         {:ok, conditions} <- parse_conditions(data["Conditions"]),
         {:ok, variants} <- parse_variants(data["Variants"]) do
      {:ok,
       %{
         key: key,
         kind: "archetype",
         name: data["Name"] || key,
         include_color_in_name: data["IncludeColorInName"] == true,
         conditions: conditions,
         variants: variants,
         common_cards: []
       }}
    end
  end

  @spec fallback(String.t(), String.t()) :: {:ok, definition_attrs()} | {:error, term()}
  def fallback(json, key) do
    with {:ok, data} <- decode(json) do
      {:ok,
       %{
         key: key,
         kind: "fallback",
         name: data["Name"] || key,
         include_color_in_name: data["IncludeColorInName"] == true,
         conditions: [],
         variants: [],
         common_cards: List.wrap(data["CommonCards"])
       }}
    end
  end

  @spec color_overrides(String.t()) :: {:ok, [override_attrs()]} | {:error, term()}
  def color_overrides(json) do
    with {:ok, data} <- decode(json) do
      lands = override_entries(data["Lands"], true)
      nonlands = override_entries(data["NonLands"], false)
      {:ok, lands ++ nonlands}
    end
  end

  @spec rows_from_files(%{String.t() => String.t()}) :: %{
          definitions: [definition_attrs()],
          overrides: [override_attrs()],
          errors: [{String.t(), term()}]
        }
  def rows_from_files(files) do
    initial = %{definitions: [], overrides: [], errors: []}

    files
    |> Enum.sort_by(fn {path, _content} -> path end)
    |> Enum.reduce(initial, fn {path, content}, acc ->
      case parse_file(path, content) do
        {:definition, attrs} -> %{acc | definitions: [attrs | acc.definitions]}
        {:overrides, overrides} -> %{acc | overrides: acc.overrides ++ overrides}
        {:error, reason} -> %{acc | errors: [{path, reason} | acc.errors]}
        :skip -> acc
      end
    end)
    |> Map.update!(:definitions, &Enum.reverse/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp parse_file(path, content) do
    key = path |> Path.basename() |> Path.rootname()

    cond do
      String.contains?(path, "Archetypes/") ->
        with_result(archetype(content, key))

      String.contains?(path, "Fallbacks/") ->
        with_result(fallback(content, key))

      Path.basename(path) == "color_overrides.json" ->
        case color_overrides(content) do
          {:ok, overrides} -> {:overrides, overrides}
          {:error, reason} -> {:error, reason}
        end

      true ->
        :skip
    end
  end

  defp with_result({:ok, attrs}), do: {:definition, attrs}
  defp with_result({:error, reason}), do: {:error, reason}

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, other} -> {:error, {:unexpected_json, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_conditions(nil), do: {:ok, []}

  defp parse_conditions(conditions) when is_list(conditions) do
    conditions
    |> Enum.reduce_while({:ok, []}, fn condition, {:ok, parsed} ->
      case parse_condition(condition) do
        {:ok, nil} -> {:cont, {:ok, parsed}}
        {:ok, attrs} -> {:cont, {:ok, [attrs | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_conditions(other), do: {:error, {:invalid_conditions, other}}

  defp parse_condition(%{"Type" => type} = condition) do
    case Map.get(@canonical_by_downcase, String.downcase(type)) do
      nil ->
        {:error, {:unknown_condition_type, type}}

      canonical ->
        case List.wrap(condition["Cards"]) do
          [] -> {:ok, nil}
          cards -> {:ok, %{"type" => canonical, "cards" => cards}}
        end
    end
  end

  defp parse_condition(other), do: {:error, {:invalid_condition, other}}

  defp parse_variants(nil), do: {:ok, []}

  defp parse_variants(variants) when is_list(variants) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, parsed} ->
      case parse_conditions(variant["Conditions"]) do
        {:ok, conditions} ->
          {:cont,
           {:ok,
            [
              %{
                "name" => variant["Name"],
                "include_color_in_name" => variant["IncludeColorInName"] == true,
                "conditions" => conditions
              }
              | parsed
            ]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_variants(other), do: {:error, {:invalid_variants, other}}

  defp override_entries(nil, _land), do: []

  defp override_entries(entries, land) when is_list(entries) do
    for %{"Name" => name, "Color" => colors} <- entries do
      %{card_name: name, land: land, colors: colors}
    end
  end
end
