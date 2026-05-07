defmodule Scry2.Collection.Composition do
  @moduledoc """
  Breakdown of a collection by rarity, colour, and type.

  Pure value derived from a list of `Scry2.Collection.Holding`. Each
  bucket counts both unique cards and total copies; renderers pick
  whichever is meaningful for their visualization.

  Colour buckets follow the standard MTG convention:

    * `"W" | "U" | "B" | "R" | "G"` — single-colour cards.
    * `"C"` — colourless (no colour identity).
    * `"M"` — multicolour (two or more colour identities).
  """

  alias Scry2.Collection.Holding

  @enforce_keys [:by_rarity, :by_colour, :by_type, :total_unique, :total_copies]
  defstruct [:by_rarity, :by_colour, :by_type, :total_unique, :total_copies]

  @type bucket :: %{owned_unique: non_neg_integer(), total_copies: non_neg_integer()}

  @type t :: %__MODULE__{
          by_rarity: %{String.t() => bucket()},
          by_colour: %{String.t() => bucket()},
          by_type: %{atom() => bucket()},
          total_unique: non_neg_integer(),
          total_copies: non_neg_integer()
        }

  @type_flags [
    creature: :is_creature,
    instant: :is_instant,
    sorcery: :is_sorcery,
    enchantment: :is_enchantment,
    artifact: :is_artifact,
    planeswalker: :is_planeswalker,
    land: :is_land,
    battle: :is_battle
  ]

  @spec from_holdings([Holding.t()]) :: t()
  def from_holdings(holdings) when is_list(holdings) do
    Enum.reduce(
      holdings,
      %__MODULE__{
        by_rarity: %{},
        by_colour: %{},
        by_type: %{},
        total_unique: 0,
        total_copies: 0
      },
      fn holding, acc ->
        rarity_key = holding.card.rarity || "unknown"
        colour_key = colour_bucket(holding.card.color_identity)

        acc
        |> bump_bucket(:by_rarity, rarity_key, holding.count)
        |> bump_bucket(:by_colour, colour_key, holding.count)
        |> bump_types(holding)
        |> Map.update!(:total_unique, &(&1 + 1))
        |> Map.update!(:total_copies, &(&1 + holding.count))
      end
    )
  end

  defp colour_bucket(nil), do: "C"
  defp colour_bucket(""), do: "C"

  defp colour_bucket(color_identity) when is_binary(color_identity) do
    distinct =
      color_identity
      |> String.graphemes()
      |> Enum.uniq()
      |> Enum.filter(&(&1 in ["W", "U", "B", "R", "G"]))

    case distinct do
      [single] -> single
      [_, _ | _] -> "M"
      [] -> "C"
    end
  end

  defp bump_types(acc, holding) do
    Enum.reduce(@type_flags, acc, fn {type, flag}, inner ->
      if Map.get(holding.card, flag, false) do
        bump_bucket(inner, :by_type, type, holding.count)
      else
        inner
      end
    end)
  end

  defp bump_bucket(struct, dimension, key, copies) do
    bucket =
      Map.get_lazy(Map.get(struct, dimension), key, fn ->
        %{owned_unique: 0, total_copies: 0}
      end)

    updated =
      bucket
      |> Map.update!(:owned_unique, &(&1 + 1))
      |> Map.update!(:total_copies, &(&1 + copies))

    Map.put(struct, dimension, Map.put(Map.get(struct, dimension), key, updated))
  end
end
