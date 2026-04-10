defmodule Scry2.Repo.Migrations.AddPercentileToRanksSnapshots do
  use Ecto.Migration

  def change do
    alter table(:ranks_snapshots) do
      add :constructed_percentile, :float
      add :constructed_leaderboard_placement, :integer
      add :limited_percentile, :float
      add :limited_leaderboard_placement, :integer
    end
  end
end
