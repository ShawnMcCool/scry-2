defmodule Scry2.Cards.ScryfallCard do
  @moduledoc """
  Schema for `cards_scryfall_cards` — an independent copy of Scryfall's
  card reference data.

  This table is **disposable**: it can be truncated and fully rebuilt from
  a single `Scry2.Cards.Scryfall.run()` call. No other table holds foreign
  keys to it.

  ## Typed columns

  The typed columns below cover the most commonly queried fields. If you
  need a new queryable column:

  1. Add the field to this schema and a migration.
  2. Update `Scryfall.parse_card/1` to extract the new field from the
     Scryfall JSON.
  3. Re-run `Scryfall.run()` to populate it from the API.

  ## Additional Scryfall fields (available via re-import)

  The Scryfall API provides ~60 fields per card. Only the most commonly
  queried fields have typed columns here. To add a new field, update the
  schema, migration, and `Scryfall.parse_card/1`, then re-run the import.

  See <https://scryfall.com/docs/api/cards> for the full field reference.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cards_scryfall_cards" do
    field :scryfall_id, :string
    field :oracle_id, :string
    field :arena_id, :integer
    field :name, :string
    field :set_code, :string
    field :collector_number, :string
    field :type_line, :string
    field :oracle_text, :string
    field :mana_cost, :string
    field :cmc, :float
    field :colors, :string, default: ""
    field :color_identity, :string, default: ""
    field :rarity, :string
    field :layout, :string
    field :booster, :boolean
    field :image_uris, :map

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for upserting from Scryfall bulk data.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :scryfall_id,
      :oracle_id,
      :arena_id,
      :name,
      :set_code,
      :collector_number,
      :type_line,
      :oracle_text,
      :mana_cost,
      :cmc,
      :colors,
      :color_identity,
      :rarity,
      :layout,
      :booster,
      :image_uris
    ])
    |> validate_required([:scryfall_id, :name, :set_code])
    |> unique_constraint(:scryfall_id)
  end
end
