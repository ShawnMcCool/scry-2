defmodule Scry2.Repo.Migrations.CreateMatchesDeckSubmissions do
  use Ecto.Migration

  def change do
    create table(:matches_deck_submissions) do
      add :match_id, references(:matches_matches, on_delete: :nilify_all)
      add :mtga_deck_id, :string, null: false
      add :name, :string

      # List of %{arena_id:, count:} entries. Stored as JSON via Ecto :map.
      add :main_deck, :map, null: false
      add :sideboard, :map, default: %{}

      add :submitted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:matches_deck_submissions, [:mtga_deck_id])
    create index(:matches_deck_submissions, [:match_id])
  end
end
