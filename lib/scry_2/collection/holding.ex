defmodule Scry2.Collection.Holding do
  @moduledoc """
  One owned-card entry in the player's collection, hydrated with the
  card's reference data and the gap to a complete playset.

  A `Holding` is the atom of a collection: pure value, derived from a
  `Scry2.Collection.Snapshot` plus a `cards_by_arena_id` lookup. Every
  read view (`Composition`, `Completion`, `CraftPlan`) operates on a list
  of `Holding`s, never on raw `cards_json` entries.

  Cards in the snapshot whose `arena_id` is not present in the lookup
  map are silently dropped — synthesis may not yet have produced a row
  for newly-released cards. The user should never see "card #91234"; if
  the card is unknown the holding is invisible until synthesis catches up.
  """

  alias Scry2.Cards.Card
  alias Scry2.Collection.Snapshot

  @enforce_keys [:arena_id, :count, :card, :copies_to_playset]
  defstruct [:arena_id, :count, :card, :copies_to_playset]

  @type t :: %__MODULE__{
          arena_id: integer(),
          count: integer(),
          card: Card.t(),
          copies_to_playset: 0..4
        }

  @playset 4

  @doc """
  Builds a `Holding` list from one snapshot. Entries whose card is
  missing from `cards_by_arena_id` are dropped.
  """
  @spec from_snapshot(Snapshot.t() | nil, %{integer() => Card.t()}) :: [t()]
  def from_snapshot(nil, _cards_by_arena_id), do: []

  def from_snapshot(%Snapshot{cards_json: cards_json}, cards_by_arena_id)
      when is_binary(cards_json) and is_map(cards_by_arena_id) do
    cards_json
    |> Snapshot.decode_entries()
    |> Enum.reduce([], fn {arena_id, count}, acc ->
      case Map.get(cards_by_arena_id, arena_id) do
        nil ->
          acc

        card ->
          [
            %__MODULE__{
              arena_id: arena_id,
              count: count,
              card: card,
              copies_to_playset: max(@playset - count, 0)
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  def from_snapshot(%Snapshot{}, _cards_by_arena_id), do: []
end
