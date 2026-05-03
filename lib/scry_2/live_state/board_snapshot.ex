defmodule Scry2.LiveState.BoardSnapshot do
  @moduledoc """
  Schema for `live_match_board_snapshots` — Chain-2 sibling of
  `Scry2.LiveState.Snapshot`.

  One row per match, captured by `Scry2.LiveState.Server` at wind-down
  when MTGA had a populated `MatchSceneManager.Instance` during the
  match. Acts as the FK target for `Scry2.LiveState.RevealedCard`
  rows (the per-card payload).

  Holds metadata only (provenance + parent-snapshot link). Querying
  for the cards themselves goes via `has_many :revealed_cards`.

  See `specs/2026-05-03-chain-2-board-state-design.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Scry2.LiveState.{RevealedCard, Snapshot}

  @type t :: %__MODULE__{}

  schema "live_match_board_snapshots" do
    belongs_to :live_state_snapshot, Snapshot
    has_many :revealed_cards, RevealedCard, foreign_key: :board_snapshot_id

    field :reader_version, :string
    field :captured_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [:live_state_snapshot_id, :reader_version, :captured_at]
  @required @cast_fields

  @doc "Build a changeset for inserting a board snapshot."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(board_snapshot, attrs) do
    board_snapshot
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
    |> unique_constraint(:live_state_snapshot_id)
    |> assoc_constraint(:live_state_snapshot)
  end
end
