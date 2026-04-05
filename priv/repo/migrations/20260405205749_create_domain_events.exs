defmodule Scry2.Repo.Migrations.CreateDomainEvents do
  use Ecto.Migration

  def change do
    create table(:domain_events) do
      # Slug like "match_created" — stable across module renames.
      add :event_type, :string, null: false

      # JSON-encoded struct fields. SQLite stores as TEXT; Ecto handles
      # serialization via the :map type.
      add :payload, :map, null: false

      # Soft reference to mtga_logs_events.id — the raw event that
      # produced this domain event (via the Translator). No FK: the
      # raw event is kept for debugging only, and deleting a raw event
      # must never cascade-delete derived state (ADR-015 replay).
      add :mtga_source_id, :integer

      # When this event happened in MTGA time (from the raw event's
      # parsed header). Nullable because not every event type carries
      # a timestamp in its header.
      add :mtga_timestamp, :utc_datetime

      add :inserted_at, :utc_datetime, null: false
    end

    # The log is read by type (projector filtering) and by source
    # (debugging "which raw event produced this?"). An index on
    # inserted_at lets us do ordered replay without a table scan.
    create index(:domain_events, [:event_type])
    create index(:domain_events, [:mtga_source_id])
    create index(:domain_events, [:inserted_at])
  end
end
