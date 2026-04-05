defmodule Scry2.Repo.Migrations.CreateCardsSets do
  use Ecto.Migration

  def change do
    create table(:cards_sets) do
      add :code, :string, null: false
      add :name, :string, null: false
      add :released_at, :date

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards_sets, [:code])
  end
end
