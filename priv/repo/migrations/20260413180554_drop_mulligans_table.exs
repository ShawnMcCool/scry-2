defmodule Scry2.Repo.Migrations.DropMulligansTable do
  use Ecto.Migration

  def change do
    drop table(:mulligans_mulligan_listing)
  end
end
