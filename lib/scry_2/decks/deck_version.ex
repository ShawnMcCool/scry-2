defmodule Scry2.Decks.DeckVersion do
  @moduledoc """
  A snapshot of a deck at the point in time when its card composition changed.

  Each row represents one version of a deck — the card list, what changed from
  the previous version, and pre-computed match stats for the period this version
  was active.

  Version 1 is the first time we saw the deck. Subsequent versions are created
  only when the main deck or sideboard actually changes (no-op edits from MTGA
  are filtered out at ingest time by `SnapshotConvert`).

  Match stats are bucketed by version: a match belongs to whichever version was
  active at `match.started_at`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "decks_deck_versions" do
    field :mtga_deck_id, :string
    field :version_number, :integer
    field :deck_name, :string
    field :action_type, :string
    field :main_deck, :map
    field :sideboard, :map
    field :main_deck_added, :map
    field :main_deck_removed, :map
    field :sideboard_added, :map
    field :sideboard_removed, :map
    field :match_wins, :integer, default: 0
    field :match_losses, :integer, default: 0
    field :on_play_wins, :integer, default: 0
    field :on_play_losses, :integer, default: 0
    field :on_draw_wins, :integer, default: 0
    field :on_draw_losses, :integer, default: 0
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(mtga_deck_id version_number main_deck sideboard occurred_at)a
  @optional_fields ~w(deck_name action_type main_deck_added main_deck_removed
                      sideboard_added sideboard_removed match_wins match_losses
                      on_play_wins on_play_losses on_draw_wins on_draw_losses)a

  def changeset(version, attrs) do
    version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:mtga_deck_id, :version_number])
  end
end
