defmodule Scry2.Repo.Migrations.CreateDecksDeckVersions do
  use Ecto.Migration

  def change do
    create table(:decks_deck_versions) do
      add :mtga_deck_id, :string, null: false
      add :version_number, :integer, null: false
      add :deck_name, :string
      add :action_type, :string
      add :main_deck, :map, null: false, default: "{}"
      add :sideboard, :map, null: false, default: "{}"
      add :main_deck_added, :map, null: false, default: "{}"
      add :main_deck_removed, :map, null: false, default: "{}"
      add :sideboard_added, :map, null: false, default: "{}"
      add :sideboard_removed, :map, null: false, default: "{}"
      add :match_wins, :integer, null: false, default: 0
      add :match_losses, :integer, null: false, default: 0
      add :on_play_wins, :integer, null: false, default: 0
      add :on_play_losses, :integer, null: false, default: 0
      add :on_draw_wins, :integer, null: false, default: 0
      add :on_draw_losses, :integer, null: false, default: 0
      add :occurred_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:decks_deck_versions, [:mtga_deck_id, :version_number])
    create index(:decks_deck_versions, [:mtga_deck_id])
    create index(:decks_deck_versions, [:occurred_at])
  end
end
