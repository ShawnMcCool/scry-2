defmodule Scry2.Repo.Migrations.AddRanksSnapshotCompositeIndex do
  use Ecto.Migration

  def change do
    create index(:ranks_snapshots, [:player_id, :season_ordinal, :occurred_at])
  end
end
