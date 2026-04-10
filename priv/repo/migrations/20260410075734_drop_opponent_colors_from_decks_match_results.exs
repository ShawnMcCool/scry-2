defmodule Scry2.Repo.Migrations.DropOpponentColorsFromDecksMatchResults do
  use Ecto.Migration

  def change do
    alter table(:decks_match_results) do
      remove :opponent_colors
    end
  end
end
