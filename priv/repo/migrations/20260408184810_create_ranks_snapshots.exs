defmodule Scry2.Repo.Migrations.CreateRanksSnapshots do
  use Ecto.Migration

  def change do
    create table(:ranks_snapshots) do
      add :player_id, :integer
      add :constructed_class, :string
      add :constructed_level, :integer
      add :constructed_step, :integer
      add :constructed_matches_won, :integer
      add :constructed_matches_lost, :integer
      add :limited_class, :string
      add :limited_level, :integer
      add :limited_step, :integer
      add :limited_matches_won, :integer
      add :limited_matches_lost, :integer
      add :season_ordinal, :integer
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ranks_snapshots, [:player_id])
    create index(:ranks_snapshots, [:occurred_at])
    create index(:ranks_snapshots, [:season_ordinal])
  end
end
