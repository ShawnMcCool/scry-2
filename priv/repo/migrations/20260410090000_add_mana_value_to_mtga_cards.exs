defmodule Scry2.Repo.Migrations.AddManaValueToMtgaCards do
  use Ecto.Migration

  def change do
    alter table(:cards_mtga_cards) do
      add :mana_value, :integer, default: 0, null: false
    end
  end
end
