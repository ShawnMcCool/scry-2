defmodule Scry2.Repo.Migrations.CreateMtgaLogsEvents do
  use Ecto.Migration

  def change do
    create table(:mtga_logs_events) do
      add :event_type, :string, null: false
      add :mtga_timestamp, :utc_datetime
      add :file_offset, :integer, null: false
      add :source_file, :string, null: false

      # Full captured payload as JSON. Retained verbatim so the ingestion
      # pipeline can be reprocessed if the parser changes. See ADR-015.
      add :raw_json, :text, null: false

      add :processed, :boolean, default: false, null: false
      add :processed_at, :utc_datetime
      add :processing_error, :text

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:mtga_logs_events, [:event_type])
    create index(:mtga_logs_events, [:processed, :id])
    create index(:mtga_logs_events, [:mtga_timestamp])
  end
end
