defmodule Scry2.Repo.Migrations.CreateProjectorWatermarks do
  use Ecto.Migration

  def change do
    create table(:projector_watermarks) do
      add :projector_name, :string, null: false
      add :last_event_id, :integer, null: false, default: 0
      add :updated_at, :utc_datetime
    end

    create unique_index(:projector_watermarks, [:projector_name])
  end
end
