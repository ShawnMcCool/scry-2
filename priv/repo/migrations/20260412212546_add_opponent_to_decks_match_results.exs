defmodule Scry2.Repo.Migrations.AddOpponentToDecksMatchResults do
  use Ecto.Migration

  def change do
    alter table(:decks_match_results) do
      add :opponent_screen_name, :string
      add :opponent_rank, :string
    end
  end
end
