defmodule Scry2.Repo.Migrations.AddMatchTagToCollectionSnapshots do
  use Ecto.Migration

  def change do
    alter table(:collection_snapshots) do
      add :mtga_match_id, :string, null: true
      add :match_phase, :string, null: true
    end

    create index(:collection_snapshots, [:mtga_match_id, :match_phase])
  end
end
