defmodule Scry2.Repo.Migrations.AddArchetypeClassificationToNetdeckingDecks do
  @moduledoc """
  Classified archetype stamp for netdecks (Metagame context vocabulary):
  the culturally established name ("Izzet Prowess"), an optional variant,
  and whether it came from a fallback rule. Nullable — decks that match
  nothing keep the synthetic label. The source-provided `archetype`
  string stays as provenance.
  """
  use Ecto.Migration

  def change do
    alter table(:netdecking_decks) do
      add :archetype_name, :string
      add :archetype_variant, :string
      add :archetype_fallback, :boolean, null: false, default: false
    end
  end
end
