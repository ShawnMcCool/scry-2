defmodule Scry2.Cards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "cards_cards" do
    field :arena_id, :integer
    field :lands17_id, :integer
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
    field :raw, :map

    belongs_to :set, Scry2.Cards.Set

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the Scryfall arena_id backfill path. Only touches
  `arena_id` — all other fields remain under 17lands ownership.
  See ADR-014.
  """
  def scryfall_changeset(card, attrs) do
    card
    |> cast(attrs, [:arena_id])
    |> validate_required([:arena_id])
    |> unique_constraint(:arena_id)
  end

  @doc """
  Changeset for the 17lands import path. Accepts `lands17_id` as the
  primary key and treats `arena_id` as optional (filled in later by the
  Scryfall backfill — see ADR-014).
  """
  def lands17_changeset(card, attrs) do
    card
    |> cast(attrs, [
      :arena_id,
      :lands17_id,
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
      :raw,
      :set_id
    ])
    |> validate_required([:lands17_id, :name])
    |> unique_constraint(:lands17_id)
    |> unique_constraint(:arena_id)
  end
end
