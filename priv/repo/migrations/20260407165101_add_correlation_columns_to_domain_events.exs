defmodule Scry2.Repo.Migrations.AddCorrelationColumnsToDomainEvents do
  use Ecto.Migration

  def change do
    alter table(:domain_events) do
      add :match_id, :string
      add :draft_id, :string
      add :session_id, :string
    end

    create index(:domain_events, [:match_id])
    create index(:domain_events, [:draft_id])
    create index(:domain_events, [:session_id])
  end
end
