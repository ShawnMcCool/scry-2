defmodule Scry2.Cards.Card do
  @moduledoc """
  Schema for `cards_cards` — the canonical card read model.

  Rows are synthesised by `Scry2.Cards.Synthesize` from `cards_mtga_cards`
  (the user's local MTGA SQLite) and `cards_scryfall_cards` (Scryfall bulk
  data). `arena_id` is the unique identity per ADR-014.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "cards_cards" do
    field :arena_id, :integer
    field :name, :string
    field :rarity, :string
    field :color_identity, :string, default: ""
    field :mana_value, :integer
    field :types, :string
    field :is_booster, :boolean, default: true
    field :is_creature, :boolean, default: false
    field :is_instant, :boolean, default: false
    field :is_sorcery, :boolean, default: false
    field :is_enchantment, :boolean, default: false
    field :is_artifact, :boolean, default: false
    field :is_planeswalker, :boolean, default: false
    field :is_land, :boolean, default: false
    field :is_battle, :boolean, default: false

    belongs_to :set, Scry2.Cards.Set

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the synthesis pipeline. `arena_id` is required and unique.
  """
  def synthesis_changeset(card, attrs) do
    card
    |> cast(attrs, [
      :arena_id,
      :name,
      :rarity,
      :color_identity,
      :mana_value,
      :types,
      :is_booster,
      :is_creature,
      :is_instant,
      :is_sorcery,
      :is_enchantment,
      :is_artifact,
      :is_planeswalker,
      :is_land,
      :is_battle,
      :set_id
    ])
    |> validate_required([:arena_id, :name])
    |> unique_constraint(:arena_id)
  end
end
