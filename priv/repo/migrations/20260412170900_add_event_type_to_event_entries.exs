defmodule Scry2.Repo.Migrations.AddEventTypeToEventEntries do
  use Ecto.Migration

  def change do
    alter table(:economy_event_entries) do
      add :event_type, :string
      add :set_code, :string
    end
  end
end
