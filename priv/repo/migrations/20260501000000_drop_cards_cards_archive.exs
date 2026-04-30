defmodule Scry2.Repo.Migrations.DropCardsCardsArchive do
  @moduledoc """
  Drops the `cards_cards_archive` table created by the 17lands→synthesis
  cutover (`20260430010000_replace_seventeen_lands_with_synthesis`). The
  archived rows were paper-only printings that 17lands listed but Arena
  never had — kept as a forensic snapshot during the cutover. After v0.27
  stabilized the MTGA + Scryfall synthesis path, that snapshot has no
  further read path.

  Down recreates the (empty) schema for parity. Archived rows themselves
  are not restored — they were never live data.
  """
  use Ecto.Migration

  def up do
    drop table(:cards_cards_archive)
  end

  def down do
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
end
