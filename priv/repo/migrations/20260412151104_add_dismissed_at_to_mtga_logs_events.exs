defmodule Scry2.Repo.Migrations.AddDismissedAtToMtgaLogsEvents do
  use Ecto.Migration

  def change do
    alter table(:mtga_logs_events) do
      add :dismissed_at, :utc_datetime
    end
  end
end
