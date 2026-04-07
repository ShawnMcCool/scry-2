defmodule Scry2.Matches.Match do
  use Ecto.Schema
  import Ecto.Changeset

  schema "matches_matches" do
    field :player_id, :integer
    field :mtga_match_id, :string
    field :event_name, :string
    field :format, :string
    field :opponent_screen_name, :string
    field :opponent_rank, :string
    field :player_rank, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :won, :boolean
    field :num_games, :integer
    field :raw_event_ids, :map

    has_many :games, Scry2.Matches.Game
    has_many :deck_submissions, Scry2.Matches.DeckSubmission

    timestamps(type: :utc_datetime)
  end

  def changeset(match, attrs) do
    match
    |> cast(attrs, [
      :player_id,
      :mtga_match_id,
      :event_name,
      :format,
      :opponent_screen_name,
      :opponent_rank,
      :player_rank,
      :started_at,
      :ended_at,
      :won,
      :num_games,
      :raw_event_ids
    ])
    |> validate_required([:mtga_match_id])
    |> unique_constraint([:player_id, :mtga_match_id])
  end
end
