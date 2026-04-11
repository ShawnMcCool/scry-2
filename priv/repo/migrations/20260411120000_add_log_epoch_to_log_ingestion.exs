defmodule Scry2.Repo.Migrations.AddLogEpochToLogIngestion do
  use Ecto.Migration

  def up do
    alter table(:mtga_logs_cursor) do
      add :log_epoch, :integer, default: 0, null: false
    end

    alter table(:mtga_logs_events) do
      add :log_epoch, :integer, default: 0, null: false
    end

    drop unique_index(:mtga_logs_events, [:source_file, :file_offset])
    create unique_index(:mtga_logs_events, [:source_file, :log_epoch, :file_offset])
  end

  def down do
    drop unique_index(:mtga_logs_events, [:source_file, :log_epoch, :file_offset])
    create unique_index(:mtga_logs_events, [:source_file, :file_offset])

    alter table(:mtga_logs_events) do
      remove :log_epoch
    end

    alter table(:mtga_logs_cursor) do
      remove :log_epoch
    end
  end
end
