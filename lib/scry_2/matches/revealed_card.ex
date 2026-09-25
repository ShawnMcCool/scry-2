defmodule Scry2.Matches.RevealedCard do
  @moduledoc """
  One card whose identity MTGA disclosed to the local client during a
  match, and the zone we most recently saw it in.

  Projection row — rebuildable from `domain_events` at any time via
  `Scry2.Matches.RevealedCardsProjection.rebuild!/1`. Never written
  outside that projector.

  Unlike the memory-derived board snapshot this replaces, the row is
  **cumulative across the whole match**: a card revealed on turn 3 and
  exiled on turn 5 is still recorded, with `current_zone` tracking where
  it ended up. See [ADR-047](../../../decisions/architecture/2026-09-25-047-revealed-cards-from-domain-events.md).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "matches_revealed_cards" do
    field :mtga_match_id, :string
    field :seat_id, :integer
    field :is_local, :boolean
    field :arena_id, :integer
    field :current_zone, :string
    field :copies_seen, :integer, default: 1
    field :first_seen_turn, :integer
    field :last_seen_turn, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :mtga_match_id,
    :seat_id,
    :is_local,
    :arena_id,
    :current_zone,
    :copies_seen,
    :first_seen_turn,
    :last_seen_turn
  ]
  @required [:mtga_match_id, :seat_id, :arena_id]

  @doc "Build a changeset for a revealed-card projection row."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(card, attrs) do
    card
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
    |> unique_constraint([:mtga_match_id, :seat_id, :arena_id])
  end
end
