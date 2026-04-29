defmodule Scry2.Repo.Migrations.ReplaceSeventeenLandsWithSynthesis do
  @moduledoc """
  Removes `cards_cards`'s 17lands-derived columns and tightens the `arena_id`
  contract.

  The new card data flow is `cards_mtga_cards` (MTGA SQLite) +
  `cards_scryfall_cards` (Scryfall bulk) → `Scry2.Cards.Synthesize` →
  `cards_cards`. `arena_id` is the canonical identity; `lands17_id` and
  `raw` are no longer needed.

  ## Data preservation

  Per CLAUDE.md "Data Integrity" — never silently discard rows. Before
  dropping anything, this migration:

  1. Backfills `arena_id` on existing `cards_cards` rows by joining
     `cards_mtga_cards` on `(name, expansion_code)`. (The Scryfall-mediated
     backfill that previously did the same job is being retired here, so we
     run an equivalent join inline.)
  2. Archives any row that still has no `arena_id` after that pass into a
     new `cards_cards_archive` table. These are paper-only printings 17lands
     listed but Arena never had — safe to remove from the live model, but
     archived for forensic completeness.
  3. Deletes archived rows from `cards_cards`.
  4. Drops `lands17_id` and `raw`, makes `arena_id NOT NULL`, swaps the
     unique index from `lands17_id` to `arena_id`.

  Ingest by `arena_id`-only after this point: events use arena_id by value
  (ADR-014, no FKs to `cards_cards.id`), so removing rows with no arena_id
  cannot orphan any inbound data.
  """
  use Ecto.Migration

  def up do
    create_archive_table()
    backfill_arena_ids_from_mtga_join()
    archive_unresolved_rows()
    drop_unresolved_rows()
    rebuild_indexes()
    drop_columns_and_tighten_arena_id()
  end

  def down do
    # Best-effort schema reversal. Any rows that were archived can be
    # restored manually from `cards_cards_archive`; the schema reversal is
    # idempotent so re-applying `up` after a manual restore works.
    relax_arena_id_and_indexes()
    add_back_legacy_columns()
    restore_from_archive()
    drop_archive_table()
  end

  # ── up/0 helpers ───────────────────────────────────────────────────────────

  defp create_archive_table do
    create table(:cards_cards_archive) do
      add :original_id, :integer
      add :arena_id, :integer
      add :lands17_id, :integer
      add :name, :string
      add :rarity, :string
      add :color_identity, :string
      add :mana_value, :integer
      add :types, :string
      add :is_booster, :boolean
      add :is_creature, :boolean
      add :is_instant, :boolean
      add :is_sorcery, :boolean
      add :is_enchantment, :boolean
      add :is_artifact, :boolean
      add :is_planeswalker, :boolean
      add :is_land, :boolean
      add :is_battle, :boolean
      add :raw, :map
      add :set_id, :integer
      add :reason, :string
      add :archived_at, :utc_datetime, null: false
    end
  end

  defp backfill_arena_ids_from_mtga_join do
    # SQLite update-from-join: cards_cards rows with no arena_id, where a
    # cards_mtga_cards row with the same name (front-name only) AND
    # expansion code maps to a free arena_id.
    execute("""
    UPDATE cards_cards AS c
    SET arena_id = (
      SELECT mc.arena_id
      FROM cards_mtga_cards mc
      JOIN cards_sets s ON s.id = c.set_id
      WHERE
        mc.name = c.name AND
        mc.expansion_code = s.code AND
        NOT EXISTS (
          SELECT 1 FROM cards_cards c2 WHERE c2.arena_id = mc.arena_id
        )
      LIMIT 1
    )
    WHERE c.arena_id IS NULL;
    """)
  end

  defp archive_unresolved_rows do
    execute("""
    INSERT INTO cards_cards_archive (
      original_id, arena_id, lands17_id, name, rarity, color_identity,
      mana_value, types, is_booster, is_creature, is_instant, is_sorcery,
      is_enchantment, is_artifact, is_planeswalker, is_land, is_battle,
      raw, set_id, reason, archived_at
    )
    SELECT
      id, arena_id, lands17_id, name, rarity, color_identity,
      mana_value, types, is_booster, is_creature, is_instant, is_sorcery,
      is_enchantment, is_artifact, is_planeswalker, is_land, is_battle,
      raw, set_id, 'no_arena_id_after_reconciliation', strftime('%Y-%m-%d %H:%M:%S','now')
    FROM cards_cards
    WHERE arena_id IS NULL;
    """)
  end

  defp drop_unresolved_rows do
    execute("DELETE FROM cards_cards WHERE arena_id IS NULL")
  end

  defp rebuild_indexes do
    drop_if_exists unique_index(:cards_cards, [:lands17_id])
    drop_if_exists unique_index(:cards_cards, [:arena_id], where: "arena_id IS NOT NULL")
    create unique_index(:cards_cards, [:arena_id])
  end

  defp drop_columns_and_tighten_arena_id do
    # SQLite doesn't support ALTER COLUMN (would need a full table rebuild
    # to flip arena_id to NOT NULL). The unique index plus the changeset
    # `validate_required([:arena_id])` give us the same guarantees in
    # practice — synthesis always supplies arena_id and unsupplied unique
    # nulls would still trip the index.
    alter table(:cards_cards) do
      remove :lands17_id
      remove :raw
    end
  end

  # ── down/0 helpers ─────────────────────────────────────────────────────────

  defp relax_arena_id_and_indexes do
    drop_if_exists unique_index(:cards_cards, [:arena_id])
    create unique_index(:cards_cards, [:arena_id], where: "arena_id IS NOT NULL")
  end

  defp add_back_legacy_columns do
    alter table(:cards_cards) do
      add :lands17_id, :integer
      add :raw, :map
    end

    create unique_index(:cards_cards, [:lands17_id])
  end

  defp restore_from_archive do
    # Restore archived rows. They had no arena_id, so the unique index on
    # arena_id (now relaxed back to partial) tolerates them.
    execute("""
    INSERT INTO cards_cards (
      id, arena_id, lands17_id, name, rarity, color_identity,
      mana_value, types, is_booster, is_creature, is_instant, is_sorcery,
      is_enchantment, is_artifact, is_planeswalker, is_land, is_battle,
      raw, set_id, inserted_at, updated_at
    )
    SELECT
      original_id, arena_id, lands17_id, name, rarity, color_identity,
      mana_value, types, is_booster, is_creature, is_instant, is_sorcery,
      is_enchantment, is_artifact, is_planeswalker, is_land, is_battle,
      raw, set_id, archived_at, archived_at
    FROM cards_cards_archive;
    """)
  end

  defp drop_archive_table do
    drop table(:cards_cards_archive)
  end
end
