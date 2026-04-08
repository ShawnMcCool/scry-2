defmodule Scry2.Repo.Migrations.ConsolidateMatchListingIntoMatches do
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :on_play, :boolean
      add :total_mulligans, :integer, default: 0
      add :total_turns, :integer, default: 0
      add :deck_colors, :string, default: ""
      add :duration_seconds, :integer
      add :format_type, :string
      add :game_results, :map
    end

    drop_if_exists table(:matches_match_listing)
  end
end
