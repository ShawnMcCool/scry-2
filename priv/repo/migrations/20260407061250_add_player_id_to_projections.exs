defmodule Scry2.Repo.Migrations.AddPlayerIdToProjections do
  use Ecto.Migration

  def change do
    alter table(:matches_matches) do
      add :player_id, references(:players), null: true
    end

    alter table(:drafts_drafts) do
      add :player_id, references(:players), null: true
    end

    create index(:matches_matches, [:player_id])
    create index(:drafts_drafts, [:player_id])

    drop unique_index(:matches_matches, [:mtga_match_id])
    create unique_index(:matches_matches, [:player_id, :mtga_match_id])

    drop unique_index(:drafts_drafts, [:mtga_draft_id])
    create unique_index(:drafts_drafts, [:player_id, :mtga_draft_id])
  end
end
