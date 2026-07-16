defmodule Scry2.Metagame.Definitions do
  @moduledoc """
  The in-memory archetype vocabulary for one format — what
  `Scry2.Metagame.ClassifyDeck` consumes. Built from
  `ArchetypeDefinition` + `ColorOverride` rows by `build/3`.

  `archetypes` and `fallbacks` are maps with atom keys mirroring the row
  shape (`key`, `name`, `include_color_in_name`, `conditions`,
  `variants`, `common_cards`); condition/variant maps keep the string
  keys they were stored with. Overrides are `%{card_name => colors}`
  lookup maps split by land/nonland.
  """

  alias Scry2.Metagame.{ArchetypeDefinition, ColorOverride}

  @type rule :: %{
          key: String.t(),
          name: String.t(),
          include_color_in_name: boolean(),
          conditions: [map()],
          variants: [map()],
          common_cards: [String.t()]
        }

  @type t :: %__MODULE__{
          format: String.t() | nil,
          archetypes: [rule()],
          fallbacks: [rule()],
          land_overrides: %{String.t() => String.t()},
          nonland_overrides: %{String.t() => String.t()}
        }

  defstruct format: nil,
            archetypes: [],
            fallbacks: [],
            land_overrides: %{},
            nonland_overrides: %{}

  @doc "Wrap a list for storage in a SQLite `:map` column."
  @spec wrap_entries(list()) :: %{String.t() => list()}
  def wrap_entries(entries) when is_list(entries), do: %{"entries" => entries}

  @doc "Unwrap a `:map` column value written by `wrap_entries/1`."
  @spec unwrap_entries(map() | nil) :: list()
  def unwrap_entries(%{"entries" => entries}) when is_list(entries), do: entries
  def unwrap_entries(_value), do: []

  @spec build(String.t(), [ArchetypeDefinition.t()], [ColorOverride.t()]) :: t()
  def build(format, definition_rows, override_rows) do
    {archetype_rows, fallback_rows} =
      Enum.split_with(definition_rows, &(&1.kind == "archetype"))

    {land_rows, nonland_rows} = Enum.split_with(override_rows, & &1.land)

    %__MODULE__{
      format: format,
      archetypes: Enum.map(archetype_rows, &to_rule/1),
      fallbacks: Enum.map(fallback_rows, &to_rule/1),
      land_overrides: Map.new(land_rows, &{&1.card_name, &1.colors}),
      nonland_overrides: Map.new(nonland_rows, &{&1.card_name, &1.colors})
    }
  end

  defp to_rule(%ArchetypeDefinition{} = row) do
    %{
      key: row.key,
      name: row.name,
      include_color_in_name: row.include_color_in_name,
      conditions: unwrap_entries(row.conditions),
      variants: unwrap_entries(row.variants),
      common_cards: unwrap_entries(row.common_cards)
    }
  end
end
