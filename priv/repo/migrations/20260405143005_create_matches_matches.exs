defmodule Scry2.Repo.Migrations.CreateMatchesMatches do
  use Ecto.Migration

  def change do
    create table(:matches_matches) do
      add :mtga_match_id, :string, null: false
      add :event_name, :string
      add :format, :string
      add :opponent_screen_name, :string
      add :opponent_rank, :string
      add :player_rank, :string
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :won, :boolean
      add :num_games, :integer

      # List of log event IDs that contributed to this match row, for
      # provenance and debugging.
      add :raw_event_ids, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:matches_matches, [:mtga_match_id])
    create index(:matches_matches, [:started_at])
    create index(:matches_matches, [:format])
  end
end
