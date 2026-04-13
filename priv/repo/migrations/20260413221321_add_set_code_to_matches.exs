defmodule Scry2.Repo.Migrations.AddSetCodeToMatches do
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :set_code, :string
    end
  end
end
