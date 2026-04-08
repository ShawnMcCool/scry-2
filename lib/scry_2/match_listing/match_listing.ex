defmodule Scry2.MatchListing.MatchListing do
  @moduledoc """
  Read-optimized projection row for the matches list page.

  Each row represents one match with precomputed display data:
  opponent info, game summary, deck colors, duration, and per-game
  results. Populated by `Scry2.MatchListing.UpdateFromEvent`.

  Disposable — can be rebuilt from the domain event log via
  `Scry2.Events.replay_projections!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "matches_match_listing" do
    field :player_id, :integer
    field :mtga_match_id, :string
    field :event_name, :string
    field :opponent_screen_name, :string
    field :opponent_rank, :string
    field :player_rank, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :won, :boolean
    field :num_games, :integer
    field :on_play, :boolean
    field :total_mulligans, :integer, default: 0
    field :total_turns, :integer, default: 0
    field :deck_colors, :string, default: ""
    field :duration_seconds, :integer
    field :format, :string
    field :format_type, :string
    field :game_results, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :player_id,
      :mtga_match_id,
      :event_name,
      :opponent_screen_name,
      :opponent_rank,
      :player_rank,
      :started_at,
      :ended_at,
      :won,
      :num_games,
      :on_play,
      :total_mulligans,
      :total_turns,
      :deck_colors,
      :duration_seconds,
      :format,
      :format_type,
      :game_results
    ])
    |> validate_required([:mtga_match_id])
    |> unique_constraint([:player_id, :mtga_match_id])
  end
end
