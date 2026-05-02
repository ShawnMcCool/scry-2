defmodule Scry2.Economy.AttributeMemoryGrants do
  @moduledoc """
  Pure attribution: turns a pair of consecutive `Scry2.Collection.Snapshot`
  rows into a list of card-grant rows for arena_ids whose collection
  count grew without any other source explaining the gain.

  Counterpart to `Scry2.Crafts.AttributeCrafts`. Crafts attribute
  wildcard spends to specific cards; this module attributes
  unexplained collection growth to memory-diff grants — the safety
  net for any acquisition the MTGA event log doesn't carry (most
  notably pack-opens, but also any future grant types we haven't
  classified).

  Attribution rule (v1):

    * If `prev` is `nil` — return `[]`. The first-ever snapshot is
      a bootstrap and represents pre-existing collection content,
      not new grants.
    * For each arena_id where `next_count > prev_count`, emit one
      grant row per new copy gained.
    * Arena_ids in the `exclude` set produce no rows. Callers
      pre-populate `exclude` with arena_ids already attributed by
      other sources in the diff window (crafts, log-driven
      `CardsGranted`).

  This module is pure: no DB, no PubSub, no logging. The caller
  resolves rarity/set lookups and persists the result.
  """

  alias Scry2.Collection.Snapshot

  @type grant_row :: %{
          arena_id: integer(),
          set_code: String.t() | nil,
          card_added: boolean(),
          vault_progress: 0
        }

  @spec attribute(Snapshot.t() | nil, Snapshot.t(), MapSet.t(integer())) :: [grant_row()]
  def attribute(nil, _next, _exclude), do: []

  def attribute(%Snapshot{} = prev, %Snapshot{} = next, %MapSet{} = exclude) do
    prev_counts = decode_entries(prev)
    next_counts = decode_entries(next)

    next_counts
    |> Enum.flat_map(fn {arena_id, next_count} ->
      cond do
        MapSet.member?(exclude, arena_id) ->
          []

        true ->
          delta = next_count - Map.get(prev_counts, arena_id, 0)

          if delta > 0 do
            List.duplicate(grant_row(arena_id), delta)
          else
            []
          end
      end
    end)
  end

  defp grant_row(arena_id) do
    %{arena_id: arena_id, set_code: nil, card_added: true, vault_progress: 0}
  end

  defp decode_entries(%Snapshot{cards_json: nil}), do: %{}

  defp decode_entries(%Snapshot{cards_json: json}) when is_binary(json) do
    json
    |> Snapshot.decode_entries()
    |> Map.new()
  end
end
