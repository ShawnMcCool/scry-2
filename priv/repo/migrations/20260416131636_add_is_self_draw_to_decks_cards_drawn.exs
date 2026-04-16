defmodule Scry2.Repo.Migrations.AddIsSelfDrawToDecksCardsDrawn do
  use Ecto.Migration

  def change do
    alter table(:decks_cards_drawn) do
      add :is_self_draw, :boolean
    end
  end
end
