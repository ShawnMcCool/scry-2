defmodule Scry2.Repo.Migrations.AddBoostersJsonToCollectionSnapshots do
  use Ecto.Migration

  def change do
    alter table(:collection_snapshots) do
      add :boosters_json, :text
    end
  end
end
