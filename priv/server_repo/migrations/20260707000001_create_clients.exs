defmodule Scry2.ServerRepo.Migrations.CreateClients do
  @moduledoc "Server-tier per-client bearer tokens (ADR-042 Phase 2). Token stored hashed."
  use Ecto.Migration

  def change do
    create table(:clients) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :label, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:clients, [:token_hash])
    create index(:clients, [:user_id])
  end
end
