defmodule Scry2.Repo.Migrations.CreatePlayers do
  use Ecto.Migration

  def change do
    create table(:players) do
      add :mtga_user_id, :string, null: false
      add :screen_name, :string, null: false
      add :first_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:players, [:mtga_user_id])
  end
end
