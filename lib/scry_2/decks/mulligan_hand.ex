defmodule Scry2.Decks.MulliganHand do
  @moduledoc """
  Projection row for a single mulligan offer, scoped to a deck.

  Each row represents one hand shown to the player during the mulligan
  phase. The `decision` field records keep/mulligan using the London
  mulligan rule: when a new hand arrives for a match, all prior rows
  for that match are marked `"mulliganed"` and the new row is inserted
  as `"kept"` (tentative until the next offer, if any).

  ## Disposable

  This table can be dropped and rebuilt from the domain event log via
  projection replay.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "decks_mulligan_hands" do
    field :mtga_deck_id, :string
    field :mtga_match_id, :string
    field :seat_id, :integer
    field :hand_size, :integer
    field :hand_arena_ids, :map
    field :land_count, :integer
    field :nonland_count, :integer
    field :total_cmc, :float
    field :cmc_distribution, :map
    field :color_distribution, :map
    field :card_names, :map
    field :event_name, :string
    field :decision, :string
    field :match_won, :boolean
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(hand, attrs) do
    hand
    |> cast(attrs, [
      :mtga_deck_id,
      :mtga_match_id,
      :seat_id,
      :hand_size,
      :hand_arena_ids,
      :land_count,
      :nonland_count,
      :total_cmc,
      :cmc_distribution,
      :color_distribution,
      :card_names,
      :event_name,
      :decision,
      :match_won,
      :occurred_at
    ])
    |> validate_required([:mtga_match_id, :hand_size, :occurred_at])
    |> unique_constraint([:mtga_match_id, :occurred_at])
  end
end
