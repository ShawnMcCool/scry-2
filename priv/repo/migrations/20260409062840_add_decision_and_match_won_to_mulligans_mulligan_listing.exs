defmodule Scry2.Repo.Migrations.AddDecisionAndMatchWonToMulligansMulliganListing do
  use Ecto.Migration

  def change do
    alter table(:mulligans_mulligan_listing) do
      add :decision, :string
      add :match_won, :boolean
    end
  end
end
