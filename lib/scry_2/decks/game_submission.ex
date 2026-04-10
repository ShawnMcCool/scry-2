defmodule Scry2.Decks.GameSubmission do
  use Ecto.Schema
  import Ecto.Changeset

  schema "decks_game_submissions" do
    field :mtga_deck_id, :string
    field :mtga_match_id, :string
    field :game_number, :integer
    field :main_deck, :map, default: %{}
    field :sideboard, :map, default: %{}
    field :submitted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :mtga_deck_id,
      :mtga_match_id,
      :game_number,
      :main_deck,
      :sideboard,
      :submitted_at
    ])
    |> validate_required([:mtga_deck_id, :mtga_match_id, :game_number])
    |> unique_constraint([:mtga_deck_id, :mtga_match_id, :game_number])
  end
end
