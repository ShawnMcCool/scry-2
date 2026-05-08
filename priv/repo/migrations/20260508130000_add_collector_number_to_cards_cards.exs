defmodule Scry2.Repo.Migrations.AddCollectorNumberToCardsCards do
  use Ecto.Migration

  def change do
    alter table(:cards_cards) do
      add :collector_number, :string
    end

    create index(:cards_cards, [:set_id, :collector_number])

    execute(
      """
      UPDATE cards_cards
      SET collector_number = (
        SELECT collector_number FROM cards_mtga_cards
        WHERE cards_mtga_cards.arena_id = cards_cards.arena_id
      )
      """,
      "UPDATE cards_cards SET collector_number = NULL"
    )
  end
end
