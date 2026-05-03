defmodule Scry2.Repo.Migrations.AddMasteryToCollectionSnapshots do
  use Ecto.Migration

  def change do
    alter table(:collection_snapshots) do
      add :mastery_tier, :integer
      add :mastery_xp_in_tier, :integer
      add :mastery_orbs, :integer
      add :mastery_season_name, :string
      add :mastery_season_ends_at, :utc_datetime
    end
  end
end
