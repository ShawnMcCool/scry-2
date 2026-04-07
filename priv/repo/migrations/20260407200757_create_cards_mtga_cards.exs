defmodule Scry2.Repo.Migrations.CreateCardsMtgaCards do
  use Ecto.Migration

  def change do
    create table(:cards_mtga_cards) do
      add :arena_id, :integer, null: false
      add :name, :string, null: false
      add :expansion_code, :string
      add :collector_number, :string
      add :rarity, :integer
      add :colors, :string, default: ""
      add :types, :string, default: ""
      add :is_token, :boolean, default: false
      add :is_digital_only, :boolean, default: false
      add :art_id, :integer
      add :power, :string, default: ""
      add :toughness, :string, default: ""
      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards_mtga_cards, [:arena_id])
    create index(:cards_mtga_cards, [:expansion_code])
    create index(:cards_mtga_cards, [:name])
  end
end
