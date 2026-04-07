defmodule Scry2.Repo.Migrations.AddMulliganHandStats do
  use Ecto.Migration

  def change do
    alter table(:mulligans_mulligan_listing) do
      add :land_count, :integer
      add :nonland_count, :integer
      add :total_cmc, :float
      add :cmc_distribution, :map
      add :color_distribution, :map
      add :card_names, :map
    end
  end
end
