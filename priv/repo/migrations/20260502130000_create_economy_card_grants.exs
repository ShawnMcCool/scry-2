defmodule Scry2.Repo.Migrations.CreateEconomyCardGrants do
  use Ecto.Migration

  def change do
    create table(:economy_card_grants) do
      add :source, :string, null: false
      add :source_id, :string
      add :cards, :map, null: false
      add :card_count, :integer, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # No idempotency-by-key constraint — this table is disposable and
    # rebuilds via Scry2.Economy.EconomyProjection.rebuild!/0 (which
    # truncates first). Live ingest is process-once via the projector
    # watermark, matching the Transaction / InventorySnapshot pattern.
    create index(:economy_card_grants, [:occurred_at])
    create index(:economy_card_grants, [:source])
  end
end
