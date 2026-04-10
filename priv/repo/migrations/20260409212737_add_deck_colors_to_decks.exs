defmodule Scry2.Repo.Migrations.AddDeckColorsToDecks do
  use Ecto.Migration

  def change do
    alter table(:decks_decks) do
      add :deck_colors, :string, default: ""
    end
  end
end
