defmodule Scry2.DeckList do
  @moduledoc """
  Shared kernel for constructed card lists — the single representation of
  "a deck's cards" used across bounded contexts.

  Both `decks_decks` and `netdecking_decks` persist card lists as
  `%{"cards" => [%{"arena_id" => id, "count" => n}]}`. This module owns that
  shape: parsing (`entries/1`), the card-identity rule (`identity_key/1` —
  downcased, trimmed card name), printing collapse (`canonical_pairs/2`), and
  name-level facets (`name_keys/2`, `display_names_by_identity/1`,
  `card_index/2` — the corpus-wide index behind card search).

  Purpose-specific outputs stay with their contexts:
  `Scry2.Decks.composition_hash/1` keeps the stored integer hash,
  `Scry2.NetDecking.CompositionKey` keeps the corpus dedup digest,
  `Scry2.NetDecking.OwnedIdentity` keeps ownership aggregation.

  Pure functions — no DB, no PubSub, owned by no bounded context; any context
  may call it. Output here is load-bearing for persisted identities
  (`composition_hash`, `composition_key`): see
  `test/scry_2/deck_list_golden_test.exs` before changing behavior.

  Note: `Scry2.Cards.printings_by_name/1` keys by SQL `lower()` (ASCII-only)
  while `identity_key/1` uses Unicode `String.downcase/1`. The mismatch
  pre-dates this module and affects only names with uppercase non-ASCII
  letters (today: four Éomer/Éowyn printings, none Standard-legal);
  consumers joining `identity_key/1` output against `printings_by_name/1`
  keys inherit that caveat.
  """

  @type entry :: %{arena_id: integer(), count: integer()}
  @type representatives :: %{optional(integer()) => integer()}

  @doc """
  Parses a stored card-list map (string- or atom-keyed) or a bare card list
  into entries. Cards without integer `arena_id` and `count` are skipped.
  `nil` and shapeless input parse as empty. Counts are not range-validated —
  0 and negative counts are preserved as stored (filtering them would change
  persisted composition hashes/keys).
  """
  @spec entries(map() | [map()] | nil) :: [entry()]
  def entries(%{"cards" => cards}) when is_list(cards), do: parse(cards)
  def entries(%{cards: cards}) when is_list(cards), do: parse(cards)
  def entries(cards) when is_list(cards), do: parse(cards)
  def entries(_shapeless), do: []

  defp parse(cards) do
    Enum.flat_map(cards, fn
      card when is_map(card) and not is_struct(card) ->
        arena_id = card["arena_id"] || card[:arena_id]
        count = card["count"] || card[:count]

        if is_integer(arena_id) and is_integer(count) do
          [%{arena_id: arena_id, count: count}]
        else
          []
        end

      _not_a_map ->
        []
    end)
  end

  @doc "Card identity: downcased, trimmed card name — the one rule everywhere."
  @spec identity_key(String.t()) :: String.t()
  def identity_key(name) when is_binary(name) do
    name |> String.trim() |> String.downcase()
  end

  @doc """
  Sorted `{representative_arena_id, total_count}` pairs with counts summed
  across printings sharing a representative. Arena_ids absent from the map
  represent themselves.
  """
  @spec canonical_pairs([entry()], representatives()) :: [{integer(), integer()}]
  def canonical_pairs(entries, representative_by_arena_id) when is_list(entries) do
    entries
    |> Enum.reduce(%{}, fn %{arena_id: arena_id, count: count}, acc ->
      representative = Map.get(representative_by_arena_id, arena_id, arena_id)
      Map.update(acc, representative, count, &(&1 + count))
    end)
    |> Enum.sort()
  end

  @doc """
  The set of card identity keys named by `entries`, resolved through
  `cards_by_arena_id` (`%{arena_id => %{name: ...}}`). Entries whose arena_id
  has no card row — or whose card has no name — are skipped.
  """
  @spec name_keys([entry()], %{optional(integer()) => map()}) :: MapSet.t(String.t())
  def name_keys(entries, cards_by_arena_id) when is_list(entries) do
    entries
    |> Enum.flat_map(fn %{arena_id: arena_id} ->
      case Map.get(cards_by_arena_id, arena_id) do
        %{name: name} when is_binary(name) -> [identity_key(name)]
        _unresolved -> []
      end
    end)
    |> MapSet.new()
  end

  @doc """
  Maps each card identity to a display spelling, taken from the lowest
  arena_id carrying that identity so the choice is stable across reloads
  regardless of map ordering. Nameless cards are skipped.
  """
  @spec display_names_by_identity(%{optional(integer()) => map()}) :: %{String.t() => String.t()}
  def display_names_by_identity(cards_by_arena_id) do
    cards_by_arena_id
    |> Enum.sort_by(fn {arena_id, _card} -> arena_id end)
    |> Enum.reduce(%{}, fn {_arena_id, card}, acc ->
      case card do
        %{name: name} when is_binary(name) -> Map.put_new(acc, identity_key(name), name)
        _nameless -> acc
      end
    end)
  end

  @doc """
  Indexes a corpus of card lists by identity: `[%{key, name, count}]` sorted
  by key, where `count` is how many of the given lists play that card. Each
  list is a `name_keys/2` set. Identities missing from `display_names` fall
  back to the key itself.
  """
  @spec card_index([MapSet.t(String.t())], %{String.t() => String.t()}) :: [
          %{key: String.t(), name: String.t(), count: pos_integer()}
        ]
  def card_index(name_key_sets, display_names) when is_list(name_key_sets) do
    name_key_sets
    |> Enum.flat_map(&MapSet.to_list/1)
    |> Enum.frequencies()
    |> Enum.map(fn {key, count} ->
      %{key: key, name: Map.get(display_names, key, key), count: count}
    end)
    |> Enum.sort_by(& &1.key)
  end
end
