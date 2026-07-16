defmodule Scry2.Repo.Migrations.AddOpponentArchetypeToMatches do
  @moduledoc """
  Post-match opponent archetype classification (Metagame vocabulary),
  derived from the cards the opponent revealed during the match.
  `opponent_archetype_confidence` is "confirmed" or "likely" — partial
  information never classifies as exact. Nullable: Limited matches and
  unknown classifications stay unstamped.
  """
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :opponent_archetype, :string
      add :opponent_archetype_confidence, :string
    end
  end
end
