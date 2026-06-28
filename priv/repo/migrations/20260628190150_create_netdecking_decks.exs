defmodule Scry2.Repo.Migrations.CreateNetdeckingDecks do
  use Ecto.Migration

  # Corpus of external reference decks (NetDecking context).
  # One row per imported/aspirational deck, scored against the user's
  # collection at read time. Idempotent on composition_hash.
  def change do
    create table(:netdecking_decks) do
      add :name, :string, null: false
      add :archetype, :string
      add :format, :string, null: false, default: "Standard"
      add :main_deck, :map, null: false
      add :sideboard, :map, null: false
      add :composition_hash, :integer
      add :source_name, :string, null: false
      add :source_url, :string
      add :fetched_at, :utc_datetime_usec, null: false
      add :unresolved_cards, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:netdecking_decks, [:composition_hash])
    create index(:netdecking_decks, [:format])
  end
end
