defmodule Scry2.Repo.Migrations.CreateCollectionDiffs do
  use Ecto.Migration

  def change do
    create table(:collection_diffs) do
      add :from_snapshot_id,
          references(:collection_snapshots, on_delete: :delete_all),
          null: true

      add :to_snapshot_id,
          references(:collection_snapshots, on_delete: :delete_all),
          null: false

      add :cards_added_json, :text, null: false
      add :cards_removed_json, :text, null: false
      add :total_acquired, :integer, null: false
      add :total_removed, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:collection_diffs, [:from_snapshot_id, :to_snapshot_id])
    create unique_index(:collection_diffs, [:to_snapshot_id])
    create index(:collection_diffs, [:inserted_at])
  end
end
