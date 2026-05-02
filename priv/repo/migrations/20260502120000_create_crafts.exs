defmodule Scry2.Repo.Migrations.CreateCrafts do
  use Ecto.Migration

  def change do
    create table(:crafts) do
      add :occurred_at_lower, :utc_datetime_usec, null: false
      add :occurred_at_upper, :utc_datetime_usec, null: false
      add :arena_id, :integer, null: false
      add :rarity, :string, null: false
      add :quantity, :integer, null: false

      add :from_snapshot_id, references(:collection_snapshots, on_delete: :nilify_all)
      add :to_snapshot_id, references(:collection_snapshots, on_delete: :nilify_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:crafts, [:to_snapshot_id, :arena_id])
    create index(:crafts, [:occurred_at_upper])
    create index(:crafts, [:arena_id])
  end
end
