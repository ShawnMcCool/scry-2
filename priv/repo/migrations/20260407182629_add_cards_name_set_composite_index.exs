defmodule Scry2.Repo.Migrations.AddCardsNameSetCompositeIndex do
  use Ecto.Migration

  def change do
    create index(:cards_cards, [:name, :set_id])
  end
end
