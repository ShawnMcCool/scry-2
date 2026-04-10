defmodule Scry2.Repo.Migrations.AddTypeColumnsToCardsCards do
  use Ecto.Migration

  def change do
    alter table(:cards_cards) do
      add :is_creature, :boolean, default: false, null: false
      add :is_instant, :boolean, default: false, null: false
      add :is_sorcery, :boolean, default: false, null: false
      add :is_enchantment, :boolean, default: false, null: false
      add :is_artifact, :boolean, default: false, null: false
      add :is_planeswalker, :boolean, default: false, null: false
      add :is_land, :boolean, default: false, null: false
      add :is_battle, :boolean, default: false, null: false
    end

    create index(:cards_cards, [:is_creature], where: "is_creature = 1")
    create index(:cards_cards, [:is_instant], where: "is_instant = 1")
    create index(:cards_cards, [:is_sorcery], where: "is_sorcery = 1")
    create index(:cards_cards, [:is_enchantment], where: "is_enchantment = 1")
    create index(:cards_cards, [:is_artifact], where: "is_artifact = 1")
    create index(:cards_cards, [:is_planeswalker], where: "is_planeswalker = 1")
    create index(:cards_cards, [:is_land], where: "is_land = 1")
    create index(:cards_cards, [:is_battle], where: "is_battle = 1")
  end
end
