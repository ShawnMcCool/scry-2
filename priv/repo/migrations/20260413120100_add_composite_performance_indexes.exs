defmodule Scry2.Repo.Migrations.AddCompositePerformanceIndexes do
  use Ecto.Migration

  def change do
    # Replace standalone player_id index with composite (player_id, started_at DESC)
    # for the common "list matches for player ordered by date" query.
    drop_if_exists index(:matches_matches, [:player_id])
    create index(:matches_matches, [:player_id, :started_at])

    # Composite (event_type, id) eliminates temp B-tree sort in replay batch queries
    # that filter by event_type and ORDER BY id.
    create index(:domain_events, [:event_type, :id])
  end
end
