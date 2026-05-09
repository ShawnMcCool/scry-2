defmodule Scry2.Repo.Migrations.AddPerfAuditIndexes do
  use Ecto.Migration

  # Covering indexes for the hot read paths flagged in the performance
  # audit. With small datasets these are mostly unused; their value
  # appears as match/deck history grows past the few-hundred mark.

  def change do
    # `Decks.list_matches_for_deck/2`, `latest_format/1`, and the rolling
    # win-rate chart all filter `mtga_deck_id = ?` and ORDER BY
    # `started_at DESC`. Without this index SQLite materializes a temp
    # b-tree per call.
    create_if_not_exists index(:decks_match_results, [:mtga_deck_id, :started_at])

    # `Matches.aggregate_stats.by_format` / `by_deck_colors` /
    # `by_deck_name` all GROUP BY one of these columns within a
    # `player_id` scope. With a single-column index on `player_id` only,
    # the GROUP BY pays a sort. Composite indexes let the planner stream
    # rows in group order.
    create_if_not_exists index(:matches_matches, [:player_id, :format])
    create_if_not_exists index(:matches_matches, [:player_id, :deck_colors])
    create_if_not_exists index(:matches_matches, [:player_id, :deck_name])
  end
end
