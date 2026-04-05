defmodule Scry2.Repo.Migrations.CreateDraftsPicks do
  use Ecto.Migration

  def change do
    create table(:drafts_picks) do
      add :draft_id, references(:drafts_drafts, on_delete: :delete_all), null: false
      add :pack_number, :integer, null: false
      add :pick_number, :integer, null: false

      # References cards_cards.arena_id by value, not FK. See ADR-014:
      # arena_id is the stable join key; we keep this table independent
      # so that a missing Scryfall backfill doesn't block ingestion.
      add :picked_arena_id, :integer, null: false

      # Arrays of arena_ids stored as JSON.
      add :pack_arena_ids, :map
      add :pool_arena_ids, :map

      add :picked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:drafts_picks, [:draft_id, :pack_number, :pick_number])
    create index(:drafts_picks, [:picked_arena_id])
  end
end
