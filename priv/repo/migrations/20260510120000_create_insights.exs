defmodule Scry2.Repo.Migrations.CreateInsights do
  use Ecto.Migration

  def change do
    create table(:insights) do
      add :detector, :string, null: false
      add :surface, :string, null: false
      add :tier, :integer, null: false
      add :title_template, :string, null: false
      add :body_template, :string
      add :stats, :map, null: false, default: %{}
      add :measurements, :map, null: false, default: %{}
      add :sample_size, :integer, null: false
      add :confidence, :float
      add :computed_at, :utc_datetime_usec, null: false
      add :superseded_at, :utc_datetime_usec
      add :last_shown_at, :utc_datetime_usec
      add :shown_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # Active rows by surface — primary read path.
    create index(:insights, [:surface, :superseded_at, :computed_at])
    # Per-detector history — for novelty / "you saw this 3 days ago" UX.
    create index(:insights, [:detector, :computed_at])
  end
end
