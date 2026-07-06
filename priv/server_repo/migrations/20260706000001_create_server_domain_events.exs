defmodule Scry2.ServerRepo.Migrations.CreateServerDomainEvents do
  @moduledoc """
  Server-tier schema foundation (client/server split, ADR-042 Phase 2).

  The shared analytics store: `users` (with the opt-out `contributes` flag) and
  a shared `domain_events` table carrying `user_id` attribution. The unique
  `(user_id, upload_key)` index is the idempotency key the ingest upserts on —
  content-addressed and stable across a client retranslation.
  """
  use Ecto.Migration

  def change do
    create table(:users) do
      add :contributes, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create table(:domain_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :client_id, :bigint
      add :upload_key, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false
      add :mtga_source_id, :bigint
      add :mtga_timestamp, :utc_datetime
      add :sequence, :integer, null: false, default: 0
      add :match_id, :string
      add :draft_id, :string
      add :session_id, :string
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:domain_events, [:user_id, :upload_key])
    create index(:domain_events, [:user_id, :event_type])
  end
end
