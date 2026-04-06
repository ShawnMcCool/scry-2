defmodule Scry2.MatchListing.Game do
  use Ecto.Schema
  import Ecto.Changeset

  schema "matches_games" do
    field :game_number, :integer
    field :on_play, :boolean
    field :num_mulligans, :integer
    field :num_turns, :integer
    field :won, :boolean
    field :main_colors, :string
    field :splash_colors, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :match, Scry2.MatchListing.Match

    timestamps(type: :utc_datetime)
  end

  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :match_id,
      :game_number,
      :on_play,
      :num_mulligans,
      :num_turns,
      :won,
      :main_colors,
      :splash_colors,
      :started_at,
      :ended_at
    ])
    |> validate_required([:match_id, :game_number])
    |> unique_constraint([:match_id, :game_number],
      name: :matches_games_match_id_game_number_index
    )
  end
end
