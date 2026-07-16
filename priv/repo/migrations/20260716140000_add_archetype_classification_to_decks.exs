defmodule Scry2.Repo.Migrations.AddArchetypeClassificationToDecks do
  @moduledoc """
  Classified archetype stamp for the player's decks (Metagame context
  vocabulary), on both the current deck row and each composition version
  — a deck's archetype can change as its list evolves. Nullable:
  non-Standard and unmatched decks stay unclassified.
  """
  use Ecto.Migration

  def change do
    alter table(:decks_decks) do
      add :archetype_name, :string
      add :archetype_variant, :string
      add :archetype_fallback, :boolean, null: false, default: false
    end

    alter table(:decks_deck_versions) do
      add :archetype_name, :string
      add :archetype_variant, :string
      add :archetype_fallback, :boolean, null: false, default: false
    end
  end
end
