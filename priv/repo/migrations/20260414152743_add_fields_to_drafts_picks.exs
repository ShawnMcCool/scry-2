defmodule Scry2.Repo.Migrations.AddFieldsToDraftsPicks do
  use Ecto.Migration

  def change do
    alter table(:drafts_picks) do
      add :auto_pick, :boolean
      add :time_remaining, :float
      add :picked_arena_ids, :map
    end
  end
end
