defmodule Scry2.Collection.DiffView do
  @moduledoc """
  Pure view helpers for rendering a `Scry2.Collection.Diff` row in the UI.

  Lives outside the LiveView so it stays unit-testable per ADR-013.
  """

  alias Scry2.Collection.Diff

  @type entry :: %{
          arena_id: integer(),
          count: pos_integer(),
          name: String.t()
        }

  @doc """
  Builds a UI-friendly entry list from a counts JSON blob, joining
  arena_ids to a `cards_by_arena_id` map (as returned by
  `Scry2.Cards.list_by_arena_ids/1`).

  Entries are sorted by descending count, then ascending arena_id.
  Unknown arena_ids fall back to the conventional `#NNNNN (unknown)`
  rendering — fix at the cards-DB completeness level, not here.
  """
  @spec entries(String.t(), %{integer() => map() | struct()}) :: [entry()]
  def entries(json, cards_by_arena_id) when is_binary(json) and is_map(cards_by_arena_id) do
    json
    |> Diff.decode_counts()
    |> Enum.map(fn {arena_id, count} ->
      %{
        arena_id: arena_id,
        count: count,
        name: name_for(arena_id, Map.get(cards_by_arena_id, arena_id))
      }
    end)
    |> Enum.sort_by(fn %{count: count, arena_id: arena_id} -> {-count, arena_id} end)
  end

  @doc """
  Returns the union of arena_ids referenced by both the acquired and
  removed payloads of a diff. Useful for batch-resolving card data
  before rendering.
  """
  @spec arena_ids(Diff.t()) :: [integer()]
  def arena_ids(%Diff{cards_added_json: added_json, cards_removed_json: removed_json}) do
    added_json
    |> Diff.decode_counts()
    |> Map.keys()
    |> Enum.concat(Map.keys(Diff.decode_counts(removed_json)))
    |> Enum.uniq()
  end

  defp name_for(arena_id, nil), do: "##{arena_id} (unknown)"
  defp name_for(_arena_id, %{name: name}) when is_binary(name) and name != "", do: name
  defp name_for(arena_id, _), do: "##{arena_id} (unknown)"
end
