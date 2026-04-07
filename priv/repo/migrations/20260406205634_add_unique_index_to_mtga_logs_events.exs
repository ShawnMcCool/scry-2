defmodule Scry2.Repo.Migrations.AddUniqueIndexToMtgaLogsEvents do
  use Ecto.Migration

  def change do
    create unique_index(:mtga_logs_events, [:source_file, :file_offset])
  end
end
