defmodule Scry2.Repo.Migrations.AddCardPoolToDraftsDrafts do
  use Ecto.Migration

  def change do
    alter table(:drafts_drafts) do
      add :card_pool_arena_ids, :map
    end
  end
end
