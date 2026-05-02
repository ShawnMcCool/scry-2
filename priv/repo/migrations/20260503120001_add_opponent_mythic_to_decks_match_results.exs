defmodule Scry2.Repo.Migrations.AddOpponentMythicToDecksMatchResults do
  use Ecto.Migration

  def change do
    alter table(:decks_match_results) do
      add :opponent_rank_mythic_percentile, :integer
      add :opponent_rank_mythic_placement, :integer
    end
  end
end
