defmodule Scry2.Repo.Migrations.CollectionSnapshotsVaultProgressToFloat do
  use Ecto.Migration

  # MTGA stores vaultProgress as a System.Double (e.g. 30.1 for "30.1 %
  # of the way to the next vault opening"); the original schema typed
  # it as :integer because static analysis couldn't tell the size.
  # Live verification on 2026-04-25 confirmed the field is f64. Switch
  # the column type to :float so we can persist the percentage with
  # its decimal precision intact.
  #
  # SQLite doesn't support ALTER COLUMN; we drop and re-add. Existing
  # snapshots produced by the scanner fallback have NULL here, so no
  # data is lost.
  def up do
    alter table(:collection_snapshots) do
      remove :vault_progress
      add :vault_progress, :float
    end
  end

  def down do
    alter table(:collection_snapshots) do
      remove :vault_progress
      add :vault_progress, :integer
    end
  end
end
