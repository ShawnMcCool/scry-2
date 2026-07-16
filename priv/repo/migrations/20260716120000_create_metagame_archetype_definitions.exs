defmodule Scry2.Repo.Migrations.CreateMetagameArchetypeDefinitions do
  @moduledoc """
  Archetype definition storage for the Metagame context: one row per
  archetype/fallback definition file from MTGOFormatData, plus manual
  color overrides. Seeded from `priv/metagame` on first read and
  refreshed daily from the upstream repo.
  """
  use Ecto.Migration

  def change do
    create table(:metagame_archetype_definitions) do
      add :format, :string, null: false
      add :key, :string, null: false
      add :kind, :string, null: false
      add :name, :string, null: false
      add :include_color_in_name, :boolean, null: false, default: false
      add :conditions, :map
      add :variants, :map
      add :common_cards, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:metagame_archetype_definitions, [:format, :kind, :key])

    create table(:metagame_color_overrides) do
      add :format, :string, null: false
      add :card_name, :string, null: false
      add :land, :boolean, null: false
      add :colors, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:metagame_color_overrides, [:format, :card_name, :land])
  end
end
