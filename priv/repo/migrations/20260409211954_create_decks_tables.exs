defmodule Scry2.Repo.Migrations.CreateDecksTables do
  use Ecto.Migration

  def change do
    # Current deck state — one row per mtga_deck_id, updated by DeckUpdated events.
    create table(:decks_decks) do
      add :mtga_deck_id, :string, null: false
      add :current_name, :string
      add :current_main_deck, :map, null: false, default: %{}
      add :current_sideboard, :map, null: false, default: %{}
      add :format, :string
      add :first_seen_at, :utc_datetime
      add :last_played_at, :utc_datetime
      add :last_updated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks_decks, [:mtga_deck_id])

    # Match outcome data — one row per (mtga_deck_id, mtga_match_id).
    # Seeded by DeckSubmitted, enriched by MatchCreated, GameCompleted, MatchCompleted.
    create table(:decks_match_results) do
      add :mtga_deck_id, :string, null: false
      add :mtga_match_id, :string, null: false
      add :won, :boolean
      add :format_type, :string
      add :event_name, :string
      add :on_play, :boolean
      add :opponent_colors, :string
      add :player_rank, :string
      add :num_games, :integer
      add :game_results, :map
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks_match_results, [:mtga_deck_id, :mtga_match_id])
    create index(:decks_match_results, [:mtga_deck_id])
    create index(:decks_match_results, [:mtga_match_id])

    # Per-game deck composition — one row per (mtga_deck_id, mtga_match_id, game_number).
    # Enables sideboard diff analysis (game 1 vs games 2/3).
    create table(:decks_game_submissions) do
      add :mtga_deck_id, :string, null: false
      add :mtga_match_id, :string, null: false
      add :game_number, :integer, null: false
      add :main_deck, :map, null: false, default: %{}
      add :sideboard, :map, null: false, default: %{}
      add :submitted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decks_game_submissions, [:mtga_deck_id, :mtga_match_id, :game_number])
    create index(:decks_game_submissions, [:mtga_deck_id])
  end
end
