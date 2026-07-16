defmodule Scry2.Metagame.ArchetypeDefinition do
  @moduledoc """
  One archetype or fallback definition from MTGOFormatData, stored as a
  row per source file. `key` is the source file stem (e.g. `"URProwess"`)
  and is the stable identity across refreshes; `name` is the display name
  the file declares (e.g. `"Prowess"`).

  `conditions` and `variants` mirror the source JSON with normalized
  condition types (see `Scry2.Metagame.ParseDefinitions`). Fallback rows
  carry `common_cards` instead of conditions. Both map columns wrap their
  lists as `%{"entries" => [...]}` because SQLite map columns store one
  JSON object.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "metagame_archetype_definitions" do
    field :format, :string
    field :key, :string
    field :kind, :string
    field :name, :string
    field :include_color_in_name, :boolean, default: false
    field :conditions, :map
    field :variants, :map
    field :common_cards, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:format, :key, :kind, :name, :include_color_in_name]
  @optional [:conditions, :variants, :common_cards]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(definition \\ %__MODULE__{}, attrs) do
    definition
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, ["archetype", "fallback"])
    |> unique_constraint([:format, :kind, :key])
  end
end
