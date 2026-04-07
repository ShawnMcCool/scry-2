defmodule Scry2.Repo.Migrations.CreateCardsScryfallCards do
  use Ecto.Migration

  def change do
    create table(:cards_scryfall_cards) do
      add :scryfall_id, :string, null: false
      add :oracle_id, :string
      add :arena_id, :integer
      add :name, :string, null: false
      add :set_code, :string, null: false
      add :collector_number, :string
      add :type_line, :string
      add :oracle_text, :text
      add :mana_cost, :string
      add :cmc, :float
      add :colors, :string, default: ""
      add :color_identity, :string, default: ""
      add :rarity, :string
      add :layout, :string
      add :image_uris, :map
      add :raw, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards_scryfall_cards, [:scryfall_id])
    create index(:cards_scryfall_cards, [:arena_id])
    create index(:cards_scryfall_cards, [:name])
    create index(:cards_scryfall_cards, [:set_code])
    create index(:cards_scryfall_cards, [:set_code, :collector_number])
  end
end
