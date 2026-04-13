defmodule Scry2.Repo.Migrations.DropRawFromScryfallCards do
  use Ecto.Migration

  def change do
    alter table(:cards_scryfall_cards) do
      remove :raw, :map, default: %{}
    end
  end
end
