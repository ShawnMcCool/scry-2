defmodule Scry2.Repo.Migrations.AddDeckNameToMatches do
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :deck_name, :string
    end
  end
end
