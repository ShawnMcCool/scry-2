defmodule Scry2.Repo.Migrations.ReplaceDraftRecordColumnsWithDeckLink do
  use Ecto.Migration

  # Wins/losses on drafts were a denormalized count maintained by a
  # reactive PubSub-driven reconciliation that ran post-rebuild against
  # matches_matches. The post-rebuild step racey against parallel
  # projector rebuild — DraftProjection finished its events first and
  # ran the reconciliation against a still-empty matches_matches,
  # producing zero counts that then sat there. Switching to read-time
  # aggregation eliminates the denormalization and the race.
  #
  # The window boundary for "which matches belong to which draft" is
  # now `deck_submitted_at` (from the `DeckSelected` event's
  # `EventSetDeckV3.CourseId`). It marks the moment the player is ready
  # to play with that draft's deck — matches always start after it.
  def change do
    alter table(:drafts_drafts) do
      remove :wins, :integer
      remove :losses, :integer

      add :deck_submitted_at, :utc_datetime
      add :mtga_deck_id, :string
    end

    create index(:drafts_drafts, [:deck_submitted_at])
  end
end
