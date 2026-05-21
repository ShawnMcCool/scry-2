defmodule Scry2.Repo.Migrations.AddStarredAndArchivedToDecks do
  use Ecto.Migration

  def change do
    alter table(:decks_decks) do
      add :starred, :boolean, null: false, default: false
      add :archived, :boolean, null: false, default: false
    end

    create index(:decks_decks, [:archived])
    create index(:decks_decks, [:starred])
  end
end
