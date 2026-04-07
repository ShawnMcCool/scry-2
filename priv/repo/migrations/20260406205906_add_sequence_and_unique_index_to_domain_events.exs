defmodule Scry2.Repo.Migrations.AddSequenceAndUniqueIndexToDomainEvents do
  use Ecto.Migration

  def change do
    alter table(:domain_events) do
      add :sequence, :integer, default: 0, null: false
    end

    # SQLite treats each NULL as distinct in UNIQUE indexes, so rows with
    # mtga_source_id = NULL naturally bypass this constraint. No partial
    # index needed (and SQLite doesn't support ON CONFLICT with partial
    # indexes anyway).
    create unique_index(:domain_events, [:mtga_source_id, :event_type, :sequence])
  end
end
