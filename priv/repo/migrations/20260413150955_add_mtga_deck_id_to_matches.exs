defmodule Scry2.Repo.Migrations.AddMtgaDeckIdToMatches do
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :mtga_deck_id, :string
    end
  end
end
