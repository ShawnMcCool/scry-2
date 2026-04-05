defmodule Scry2.Repo.Migrations.CreateMatchesGames do
  use Ecto.Migration

  def change do
    create table(:matches_games) do
      add :match_id, references(:matches_matches, on_delete: :delete_all), null: false
      add :game_number, :integer, null: false
      add :on_play, :boolean
      add :num_mulligans, :integer
      add :num_turns, :integer
      add :won, :boolean
      add :main_colors, :string
      add :splash_colors, :string
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:matches_games, [:match_id, :game_number])
  end
end
