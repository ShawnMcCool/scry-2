defmodule Scry2.Repo.Migrations.CreateMulligansHands do
  use Ecto.Migration

  def change do
    create table(:mulligans_mulligan_listing) do
      add :player_id, :integer
      add :mtga_match_id, :string
      add :event_name, :string
      add :seat_id, :integer
      add :hand_size, :integer, null: false
      add :hand_arena_ids, :map
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:mulligans_mulligan_listing, [:player_id])
    create index(:mulligans_mulligan_listing, [:mtga_match_id])
    create index(:mulligans_mulligan_listing, [:event_name])
    create unique_index(:mulligans_mulligan_listing, [:mtga_match_id, :occurred_at])
  end
end
