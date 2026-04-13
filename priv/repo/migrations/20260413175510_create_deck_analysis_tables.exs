defmodule Scry2.Repo.Migrations.CreateDeckAnalysisTables do
  use Ecto.Migration

  def change do
    create table(:decks_mulligan_hands) do
      add :mtga_deck_id, :string
      add :mtga_match_id, :string, null: false
      add :seat_id, :integer
      add :hand_size, :integer, null: false
      add :hand_arena_ids, :map
      add :land_count, :integer
      add :nonland_count, :integer
      add :total_cmc, :float
      add :cmc_distribution, :map
      add :color_distribution, :map
      add :card_names, :map
      add :event_name, :string
      add :decision, :string
      add :match_won, :boolean
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks_mulligan_hands, [:mtga_match_id, :occurred_at])
    create index(:decks_mulligan_hands, [:mtga_deck_id])

    create table(:decks_cards_drawn) do
      add :mtga_deck_id, :string
      add :mtga_match_id, :string, null: false
      add :game_number, :integer
      add :card_arena_id, :integer
      add :card_name, :string
      add :turn_number, :integer
      add :match_won, :boolean
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks_cards_drawn, [
             :mtga_match_id,
             :game_number,
             :card_arena_id,
             :occurred_at
           ])

    create index(:decks_cards_drawn, [:mtga_deck_id])
    create index(:decks_cards_drawn, [:mtga_deck_id, :card_arena_id])
  end
end
