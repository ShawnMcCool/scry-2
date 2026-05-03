defmodule Scry2.LiveState.RevealedCard do
  @moduledoc """
  One card visible in a (seat, zone) at the moment of a board
  snapshot.

  Inserted in bulk by `Scry2.LiveState.record_final_board/2` from the
  walker's per-(seat, zone) arena_id lists. `position` preserves the
  ordering MTGA stored the cards in, so rendering can show play-order
  (battlefield) or stack-order (Stack zone, future v2).

  v1 only carries Battlefield rows (`zone_id == 4`).

  See `specs/2026-05-03-chain-2-board-state-design.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Scry2.LiveState.BoardSnapshot

  @type t :: %__MODULE__{}

  schema "live_match_revealed_cards" do
    belongs_to :board_snapshot, BoardSnapshot

    field :seat_id, :integer
    field :zone_id, :integer
    field :arena_id, :integer
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [:board_snapshot_id, :seat_id, :zone_id, :arena_id, :position]
  @required @cast_fields

  @doc "Build a changeset for inserting a revealed-card row."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(card, attrs) do
    card
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
    |> assoc_constraint(:board_snapshot)
  end
end
