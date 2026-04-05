defmodule Scry2.Repo.Migrations.CreateDraftsDrafts do
  use Ecto.Migration

  def change do
    create table(:drafts_drafts) do
      add :mtga_draft_id, :string, null: false
      add :event_name, :string
      add :format, :string
      add :set_code, :string
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :wins, :integer
      add :losses, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:drafts_drafts, [:mtga_draft_id])
    create index(:drafts_drafts, [:set_code])
    create index(:drafts_drafts, [:started_at])
  end
end
