defmodule Scry2.Cards.ScryfallCard do
  @moduledoc """
  Schema for `cards_scryfall_cards` — an independent copy of Scryfall's
  card reference data.

  This table is **disposable**: it can be truncated and fully rebuilt from
  a single `Scry2.Cards.Scryfall.run()` call. No other table holds foreign
  keys to it.

  ## Typed columns

  The typed columns below cover the most commonly queried fields. The `raw`
  column preserves the complete Scryfall JSON (~60 fields per card) for
  forward-compatibility. If you need a new queryable column:

  1. Add the field to this schema and a migration.
  2. The next `Scryfall.run()` will populate it from the `raw` data.
  3. No data loss — the `raw` column already contains every field.

  ## All available Scryfall fields (in `raw`)

  Card identity: `id` (scryfall_id), `oracle_id`, `arena_id`, `mtgo_id`,
  `multiverse_ids`, `cardmarket_id`, `tcgplayer_id`, `object`, `lang`.

  Card content: `name`, `type_line`, `oracle_text`, `mana_cost`, `cmc`,
  `colors`, `color_identity`, `keywords`, `layout`, `flavor_text`.

  Printing: `set`, `set_name`, `set_id`, `set_type`, `collector_number`,
  `rarity`, `released_at`, `reprint`, `variation`, `booster`, `digital`.

  Images: `image_uris` (map with `small`, `normal`, `large`, `png`,
  `art_crop`, `border_crop`), `image_status`, `highres_image`.
  Note: DFCs store images under `card_faces[].image_uris` instead.

  Legalities: `legalities` (map of format → status, ~21 formats).

  Prices: `prices` (map of `usd`, `usd_foil`, `eur`, `tix`).

  Art: `artist`, `artist_ids`, `illustration_id`, `frame`, `full_art`,
  `textless`, `border_color`, `story_spotlight`.

  Booleans: `foil`, `nonfoil`, `oversized`, `promo`, `reserved`,
  `game_changer`.

  Games: `games` (list: `paper`, `mtgo`, `arena`).

  External links: `scryfall_uri`, `uri`, `rulings_uri`,
  `prints_search_uri`, `purchase_uris`, `related_uris`.

  Related cards: `all_parts` (list of related card objects).

  Card faces (DFCs): `card_faces` (list of face objects with their own
  `name`, `mana_cost`, `oracle_text`, `image_uris`, etc.).
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
    field :raw, :map

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
      :image_uris,
      :raw
    ])
    |> validate_required([:scryfall_id, :name, :set_code])
    |> unique_constraint(:scryfall_id)
  end
end
