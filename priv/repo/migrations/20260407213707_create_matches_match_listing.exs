defmodule Scry2.Repo.Migrations.CreateMatchesMatchListing do
  use Ecto.Migration

  def change do
    create table(:matches_match_listing) do
      add :player_id, :integer
      add :mtga_match_id, :string, null: false
      add :event_name, :string
      add :opponent_screen_name, :string
      add :opponent_rank, :string
      add :player_rank, :string
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :won, :boolean
      add :num_games, :integer
      add :on_play, :boolean
      add :total_mulligans, :integer, default: 0
      add :total_turns, :integer, default: 0
      add :deck_colors, :string, default: ""
      add :duration_seconds, :integer
      add :game_results, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:matches_match_listing, [:player_id, :mtga_match_id])
    create index(:matches_match_listing, [:player_id])
    create index(:matches_match_listing, [:event_name])
    create index(:matches_match_listing, [:started_at])
  end
end
