defmodule Scry2.Repo.Migrations.ScopeNetdeckingDedupByFormat do
  use Ecto.Migration

  # composition_hash was a global dedup key — a maindeck-identical hash
  # collides across formats now that netdecking_decks holds more than
  # Standard. Scope the index (and IngestDecklist's lookup) to the pair.
  def change do
    drop index(:netdecking_decks, [:composition_hash])
    create index(:netdecking_decks, [:composition_hash, :format])
  end
end
