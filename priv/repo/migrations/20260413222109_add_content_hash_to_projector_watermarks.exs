defmodule Scry2.Repo.Migrations.AddContentHashToProjectorWatermarks do
  use Ecto.Migration

  def change do
    alter table(:projector_watermarks) do
      add :content_hash, :string
    end
  end
end
