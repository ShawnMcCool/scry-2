defmodule Scry2.Repo.Migrations.CreateCardsCards do
  use Ecto.Migration

  def change do
    create table(:cards_cards) do
      # MTGA's 5-digit card identifier. Primary join key for all log-derived
      # data. Nullable at row-creation time because 17lands' cards.csv uses
      # its own id; arena_id is backfilled via Scryfall or direct log
      # observation. See ADR-014.
      add :arena_id, :integer

      # 17lands' internal id column — primary upsert target for cards.csv
      # refreshes.
      add :lands17_id, :integer, null: false

      add :name, :string, null: false
      add :set_id, references(:cards_sets, on_delete: :nilify_all)
      add :rarity, :string
      add :color_identity, :string, default: ""
      add :mana_value, :integer
      add :types, :string
      add :is_booster, :boolean, default: true, null: false

      # Original CSV row encoded as JSON for forward-compatibility with
      # future 17lands column additions.
      add :raw, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards_cards, [:lands17_id])
    create unique_index(:cards_cards, [:arena_id], where: "arena_id IS NOT NULL")
    create index(:cards_cards, [:name])
    create index(:cards_cards, [:set_id])
  end
end
