defmodule Scry2.Repo.Migrations.CreateIngestionState do
  use Ecto.Migration

  def change do
    create table(:ingestion_state) do
      add :version, :integer, null: false, default: 1
      add :last_raw_event_id, :integer, null: false, default: 0
      add :session, :map, null: false, default: %{}
      add :match, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end
  end
end
