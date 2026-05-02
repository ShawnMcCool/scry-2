defmodule Scry2.Repo.Migrations.AddOpponentMythicToMatches do
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :opponent_rank_mythic_percentile, :integer
      add :opponent_rank_mythic_placement, :integer
    end
  end
end
