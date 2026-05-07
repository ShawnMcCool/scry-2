defmodule Scry2.Collection.CraftPlan do
  @moduledoc """
  Crafting view of a collection: incomplete playsets paired with the
  player's wildcard balance.

  Pure value derived from a list of `Scry2.Collection.Holding` and the
  `Scry2.Collection.Snapshot` (which carries wildcard counts). The plan
  is intentionally informational — it does not greedily allocate
  wildcards or recommend specific crafts. Renderers display the gap; the
  player decides.

  Basics are excluded from the playset list: a card with `is_land =
  true` and `is_booster = false` cannot be crafted with wildcards and is
  effectively unlimited in MTGA, so listing them as "incomplete" is
  noise.
  """

  alias Scry2.Collection.Holding
  alias Scry2.Collection.Snapshot

  @enforce_keys [:incomplete_playsets, :wildcards_owned, :wildcards_needed_by_rarity]
  defstruct [:incomplete_playsets, :wildcards_owned, :wildcards_needed_by_rarity]

  @type playset_row :: %{holding: Holding.t(), copies_needed: 1..4}

  @type wildcard_balance :: %{
          required(String.t()) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          incomplete_playsets: [playset_row()],
          wildcards_owned: wildcard_balance(),
          wildcards_needed_by_rarity: %{String.t() => non_neg_integer()}
        }

  @rarities ~w(mythic rare uncommon common)
  @rarity_priority %{"mythic" => 0, "rare" => 1, "uncommon" => 2, "common" => 3}

  @spec from_holdings([Holding.t()], Snapshot.t()) :: t()
  def from_holdings(holdings, %Snapshot{} = snapshot) when is_list(holdings) do
    rows =
      holdings
      |> Enum.reject(&basic_land?/1)
      |> Enum.filter(&(&1.copies_to_playset > 0))
      |> Enum.map(&%{holding: &1, copies_needed: &1.copies_to_playset})
      |> Enum.sort_by(&sort_key/1)

    needed =
      Enum.reduce(rows, %{}, fn %{holding: holding, copies_needed: n}, acc ->
        rarity = holding.card.rarity || "unknown"
        Map.update(acc, rarity, n, &(&1 + n))
      end)

    %__MODULE__{
      incomplete_playsets: rows,
      wildcards_owned: %{
        "common" => snapshot.wildcards_common || 0,
        "uncommon" => snapshot.wildcards_uncommon || 0,
        "rare" => snapshot.wildcards_rare || 0,
        "mythic" => snapshot.wildcards_mythic || 0
      },
      wildcards_needed_by_rarity: needed
    }
  end

  @doc "Net wildcards still needed after applying the player's balance."
  @spec gap(t()) :: %{String.t() => integer()}
  def gap(%__MODULE__{wildcards_owned: owned, wildcards_needed_by_rarity: needed}) do
    @rarities
    |> Map.new(fn rarity ->
      have = Map.get(owned, rarity, 0)
      need = Map.get(needed, rarity, 0)
      {rarity, max(need - have, 0)}
    end)
  end

  defp basic_land?(%Holding{card: card}) do
    Map.get(card, :is_land, false) and not Map.get(card, :is_booster, true)
  end

  defp sort_key(%{holding: %Holding{card: card}}) do
    rarity = card.rarity || "unknown"
    name = card.name || ""
    {Map.get(@rarity_priority, rarity, 99), name}
  end
end
