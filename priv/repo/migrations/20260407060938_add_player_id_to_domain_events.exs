defmodule Scry2.Repo.Migrations.AddPlayerIdToDomainEvents do
  use Ecto.Migration

  def change do
    alter table(:domain_events) do
      add :player_id, references(:players), null: true
    end

    create index(:domain_events, [:player_id])
  end
end
