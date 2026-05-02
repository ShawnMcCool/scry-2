defmodule Scry2.Repo.Migrations.AddSnapshotPairToEconomyCardGrants do
  use Ecto.Migration

  def change do
    alter table(:economy_card_grants) do
      add :from_snapshot_id, references(:collection_snapshots, on_delete: :nilify_all)
      add :to_snapshot_id, references(:collection_snapshots, on_delete: :nilify_all)
    end

    # SQLite treats NULLs as distinct in UNIQUE constraints, so this index
    # enforces uniqueness for memory-diff rows (one row per to_snapshot_id)
    # while allowing many log-driven rows whose to_snapshot_id is NULL.
    create unique_index(:economy_card_grants, [:to_snapshot_id])
  end
end
