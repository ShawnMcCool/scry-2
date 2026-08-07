defmodule Scry2.Buildability.CollectionPosition do
  @moduledoc """
  Stage 1 of the buildability pipeline: the player's standing against a
  pool of cards right now — what they own, what wildcards they hold,
  each card's rarity, and which cards cost nothing to acquire.

  Assembled once and reused across every list scored in the same
  request: `Scry2.Collection` supplies owned copies and (usually)
  wildcard balances, `Scry2.Economy` supplies the wildcard fallback,
  `Scry2.Cards` supplies printings for the ownership roll-up.

  `owned` is keyed by the *representative* arena_id of each card in the
  pool, with copies summed across every printing of that card's name —
  MTGA counts playsets by name, and a list can reference a printing the
  player doesn't hold. See `Scry2.Buildability.OwnedIdentity`.

  `collection_known?` is false when no snapshot exists at all. An absent
  snapshot means *unknown* ownership, not zero ownership — callers must
  not present "you are missing every card" as a fact.
  """

  alias Scry2.Buildability.OwnedIdentity
  alias Scry2.Buildability.ScoreCardList
  alias Scry2.Cards
  alias Scry2.Collection
  alias Scry2.Collection.Snapshot
  alias Scry2.Economy

  @enforce_keys [:owned, :wildcards, :rarities, :free_arena_ids, :collection_known?]
  defstruct [:owned, :wildcards, :rarities, :free_arena_ids, :collection_known?]

  @type wildcard_map :: %{
          common: non_neg_integer(),
          uncommon: non_neg_integer(),
          rare: non_neg_integer(),
          mythic: non_neg_integer()
        }
  @type t :: %__MODULE__{
          owned: %{optional(integer()) => non_neg_integer()},
          wildcards: wildcard_map(),
          rarities: %{optional(integer()) => String.t() | nil},
          free_arena_ids: MapSet.t(),
          collection_known?: boolean()
        }

  @empty_wildcards %{common: 0, uncommon: 0, rare: 0, mythic: 0}

  @doc """
  Reads the current collection and projects it onto `cards_by_arena_id`
  — the card reference for every card that will be scored.
  """
  @spec current(%{optional(integer()) => map()}) :: t()
  def current(cards_by_arena_id) do
    snapshot = Collection.current()

    %__MODULE__{
      owned: owned_by_identity(raw_owned(snapshot), cards_by_arena_id),
      wildcards: wildcards(snapshot),
      rarities: Map.new(cards_by_arena_id, fn {arena_id, card} -> {arena_id, rarity(card)} end),
      free_arena_ids: ScoreCardList.default_free_ids(cards_by_arena_id),
      collection_known?: not is_nil(snapshot)
    }
  end

  defp raw_owned(nil), do: %{}

  defp raw_owned(%Snapshot{} = snapshot),
    do: snapshot.cards_json |> Snapshot.decode_entries() |> Map.new()

  # Aggregates raw arena_id-keyed ownership across printings onto each pool
  # card's representative arena_id (card-name identity).
  defp owned_by_identity(raw_owned, cards_by_arena_id) do
    names = cards_by_arena_id |> Map.values() |> Enum.map(& &1.name) |> Enum.uniq()
    printings = Cards.printings_by_name(names)
    OwnedIdentity.owned_by_representative(cards_by_arena_id, raw_owned, printings)
  end

  defp wildcards(nil), do: economy_wildcards()

  # The memory walker stamps all four wildcard balances; the fallback scanner
  # stamps none. A balance-less snapshot means "the reader couldn't see
  # wildcards", not "zero wildcards" — the log-derived economy inventory is
  # then the best available source.
  defp wildcards(%Snapshot{} = snapshot) do
    balances = [
      snapshot.wildcards_common,
      snapshot.wildcards_uncommon,
      snapshot.wildcards_rare,
      snapshot.wildcards_mythic
    ]

    if Enum.all?(balances, &is_nil/1) do
      economy_wildcards()
    else
      %{
        common: snapshot.wildcards_common || 0,
        uncommon: snapshot.wildcards_uncommon || 0,
        rare: snapshot.wildcards_rare || 0,
        mythic: snapshot.wildcards_mythic || 0
      }
    end
  end

  defp economy_wildcards do
    case Economy.latest_inventory() do
      nil ->
        @empty_wildcards

      inventory ->
        %{
          common: inventory.wildcards_common || 0,
          uncommon: inventory.wildcards_uncommon || 0,
          rare: inventory.wildcards_rare || 0,
          mythic: inventory.wildcards_mythic || 0
        }
    end
  end

  defp rarity(%{rarity: rarity}) when is_binary(rarity), do: rarity
  defp rarity(_card), do: nil
end
