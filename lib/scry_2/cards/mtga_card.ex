defmodule Scry2.Cards.MtgaCard do
  @moduledoc """
  Schema for `cards_mtga_cards` — card identity data imported from
  the MTGA client's local `Raw_CardDatabase` SQLite file.

  This is the **primary card identity source** in Scry2. Every arena_id
  that MTGA assigns has an entry here, including tokens, digital-only
  cards, and promo printings that external sources like Scryfall may not
  catalog.

  The table is disposable and idempotent — re-run
  `Scry2.Cards.MtgaClientData.run()` after any MTGA update to refresh.

  ## Rarity values (MTGA enum)

  0 = token/special, 1 = basic land, 2 = common, 3 = uncommon,
  4 = rare, 5 = mythic rare.

  ## Colors and Types

  Stored as comma-separated integer strings matching MTGA's internal
  enum system (e.g., colors `"1,3"` = White,Black; types `"2"` = Creature).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cards_mtga_cards" do
    field :arena_id, :integer
    field :name, :string
    field :expansion_code, :string
    field :collector_number, :string
    field :rarity, :integer
    field :colors, :string, default: ""
    field :types, :string, default: ""
    field :is_token, :boolean, default: false
    field :is_digital_only, :boolean, default: false
    field :art_id, :integer
    field :power, :string, default: ""
    field :toughness, :string, default: ""
    field :mana_value, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :arena_id,
      :name,
      :expansion_code,
      :collector_number,
      :rarity,
      :colors,
      :types,
      :is_token,
      :is_digital_only,
      :art_id,
      :power,
      :toughness,
      :mana_value
    ])
    |> validate_required([:arena_id, :name])
    |> unique_constraint(:arena_id)
  end
end
