defmodule Scry2.Repo.Migrations.CreateCollectionSnapshots do
  use Ecto.Migration

  def change do
    create table(:collection_snapshots) do
      add :snapshot_ts, :utc_datetime_usec, null: false
      add :reader_version, :string, null: false
      # "walker" | "fallback_scan"; see ADR 034.
      add :reader_confidence, :string, null: false
      add :mtga_build_hint, :string
      add :card_count, :integer, null: false
      add :total_copies, :integer, null: false
      add :cards_json, :text, null: false
      add :wildcards_common, :integer
      add :wildcards_uncommon, :integer
      add :wildcards_rare, :integer
      add :wildcards_mythic, :integer
      add :gold, :integer
      add :gems, :integer
      add :vault_progress, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:collection_snapshots, [:snapshot_ts])
  end
end
