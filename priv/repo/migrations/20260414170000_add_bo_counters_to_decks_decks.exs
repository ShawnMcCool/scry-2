defmodule Scry2.Repo.Migrations.AddBoCountersToDecksDecks do
  use Ecto.Migration

  def up do
    alter table(:decks_decks) do
      add :bo1_wins, :integer, default: 0, null: false
      add :bo1_losses, :integer, default: 0, null: false
      add :bo3_wins, :integer, default: 0, null: false
      add :bo3_losses, :integer, default: 0, null: false
    end

    # Backfill from existing match results in one pass per format bucket.
    # Uses the same bo1/bo3 classification logic as aggregate_stats_for_decks/1.
    execute("""
    UPDATE decks_decks SET
      bo1_wins = COALESCE((
        SELECT SUM(CASE WHEN won = 1 THEN 1 ELSE 0 END)
        FROM decks_match_results
        WHERE mtga_deck_id = decks_decks.mtga_deck_id
          AND won IS NOT NULL
          AND COALESCE(format_type, '') != 'Traditional'
          AND COALESCE(num_games, 1) <= 1
      ), 0),
      bo1_losses = COALESCE((
        SELECT SUM(CASE WHEN won = 0 THEN 1 ELSE 0 END)
        FROM decks_match_results
        WHERE mtga_deck_id = decks_decks.mtga_deck_id
          AND won IS NOT NULL
          AND COALESCE(format_type, '') != 'Traditional'
          AND COALESCE(num_games, 1) <= 1
      ), 0),
      bo3_wins = COALESCE((
        SELECT SUM(CASE WHEN won = 1 THEN 1 ELSE 0 END)
        FROM decks_match_results
        WHERE mtga_deck_id = decks_decks.mtga_deck_id
          AND won IS NOT NULL
          AND (format_type = 'Traditional' OR num_games > 1)
      ), 0),
      bo3_losses = COALESCE((
        SELECT SUM(CASE WHEN won = 0 THEN 1 ELSE 0 END)
        FROM decks_match_results
        WHERE mtga_deck_id = decks_decks.mtga_deck_id
          AND won IS NOT NULL
          AND (format_type = 'Traditional' OR num_games > 1)
      ), 0)
    """)
  end

  def down do
    alter table(:decks_decks) do
      remove :bo1_wins
      remove :bo1_losses
      remove :bo3_wins
      remove :bo3_losses
    end
  end
end
