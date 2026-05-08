defmodule Scry2.Repo.Migrations.AddSetNameAndReleasedAtToScryfallCards do
  use Ecto.Migration

  def change do
    alter table(:cards_scryfall_cards) do
      add :set_name, :string
      add :released_at, :date
    end
  end
end
