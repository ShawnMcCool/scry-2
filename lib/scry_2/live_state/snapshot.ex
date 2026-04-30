defmodule Scry2.LiveState.Snapshot do
  @moduledoc """
  Schema for `live_state_snapshots` — final memory-read snapshot
  captured at end-of-match by `Scry2.LiveState`.

  See the migration's `@moduledoc` for the rationale; in short, this
  row carries the data that the MTGA log stream cannot provide
  (opponent rank, opponent commander grpIds, point-in-time format /
  variant context).

  `*_commander_grp_ids` are stored as JSON-encoded arrays of
  integers via `Scry2.LiveState.IntList` — small cardinality (1 or 2
  per match) doesn't justify a join table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Scry2.LiveState.IntList

  @type t :: %__MODULE__{}

  schema "live_state_snapshots" do
    field :mtga_match_id, :string

    field :local_screen_name, :string
    field :local_seat_id, :integer
    field :local_team_id, :integer
    field :local_ranking_class, :integer
    field :local_ranking_tier, :integer
    field :local_mythic_percentile, :integer
    field :local_mythic_placement, :integer
    field :local_commander_grp_ids, IntList

    field :opponent_screen_name, :string
    field :opponent_seat_id, :integer
    field :opponent_team_id, :integer
    field :opponent_ranking_class, :integer
    field :opponent_ranking_tier, :integer
    field :opponent_mythic_percentile, :integer
    field :opponent_mythic_placement, :integer
    field :opponent_commander_grp_ids, IntList

    field :format, :integer
    field :variant, :integer
    field :session_type, :integer
    field :is_practice_game, :boolean, default: false
    field :is_private_game, :boolean, default: false

    field :reader_version, :string
    field :captured_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :mtga_match_id,
    :local_screen_name,
    :local_seat_id,
    :local_team_id,
    :local_ranking_class,
    :local_ranking_tier,
    :local_mythic_percentile,
    :local_mythic_placement,
    :local_commander_grp_ids,
    :opponent_screen_name,
    :opponent_seat_id,
    :opponent_team_id,
    :opponent_ranking_class,
    :opponent_ranking_tier,
    :opponent_mythic_percentile,
    :opponent_mythic_placement,
    :opponent_commander_grp_ids,
    :format,
    :variant,
    :session_type,
    :is_practice_game,
    :is_private_game,
    :reader_version,
    :captured_at
  ]

  @required [:mtga_match_id, :reader_version, :captured_at]

  @doc "Build a changeset for inserting/upserting a final snapshot."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
    |> unique_constraint(:mtga_match_id)
  end
end
