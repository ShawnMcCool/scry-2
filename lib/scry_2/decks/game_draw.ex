defmodule Scry2.Decks.GameDraw do
  @moduledoc """
  Projection row for a card drawn during a game, scoped to a deck.

  Each row represents one card draw event from a GRE `CardDrawn`
  annotation. Combined with `decks_mulligan_hands` (for opening hand
  data), this table enables card-level performance metrics:

    * **GIH WR** — Game in Hand Win Rate (opening hand + drawn)
    * **GD WR** — Games Drawn Win Rate (drawn during game, not opener)
    * **GND WR** — Game Not Drawn Win Rate (in deck but never seen)

  ## Disposable

  This table can be dropped and rebuilt from the domain event log via
  projection replay.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "decks_cards_drawn" do
    field :mtga_deck_id, :string
    field :mtga_match_id, :string
    field :game_number, :integer
    field :card_arena_id, :integer
    field :card_name, :string
    field :turn_number, :integer
    field :match_won, :boolean
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(draw, attrs) do
    draw
    |> cast(attrs, [
      :mtga_deck_id,
      :mtga_match_id,
      :game_number,
      :card_arena_id,
      :card_name,
      :turn_number,
      :match_won,
      :occurred_at
    ])
    |> validate_required([:mtga_match_id, :occurred_at])
    |> unique_constraint([:mtga_match_id, :game_number, :card_arena_id, :occurred_at])
  end
end
