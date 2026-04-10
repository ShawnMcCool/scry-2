defmodule Scry2.Decks.MatchResult do
  use Ecto.Schema
  import Ecto.Changeset

  schema "decks_match_results" do
    field :mtga_deck_id, :string
    field :mtga_match_id, :string
    field :won, :boolean
    field :format_type, :string
    field :event_name, :string
    field :on_play, :boolean
    field :player_rank, :string
    field :num_games, :integer
    field :game_results, :map
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :mtga_deck_id,
      :mtga_match_id,
      :won,
      :format_type,
      :event_name,
      :on_play,
      :player_rank,
      :num_games,
      :game_results,
      :started_at,
      :completed_at
    ])
    |> validate_required([:mtga_deck_id, :mtga_match_id])
    |> unique_constraint([:mtga_deck_id, :mtga_match_id])
  end
end
