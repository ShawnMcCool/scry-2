defmodule Scry2.Collection.CraftPlan do
  @moduledoc """
  Crafting view of a collection: incomplete playsets paired with the
  player's wildcard balance.

  Pure value derived from a list of `Scry2.Collection.Holding` and the
  `Scry2.Collection.Snapshot` (which carries wildcard counts). The plan
  is intentionally informational — it does not greedily allocate
  wildcards or recommend specific crafts. Renderers display the gap; the
  player decides.

  ## Rolling up reprints by name

  MTGA caps playsets by oracle name across reprints — owning 4 copies
  of Essence Scatter across any combination of sets is a complete
  playset everywhere it's reprinted, and further copies become vault
  progress. This module mirrors that: holdings of the same card name
  across different sets collapse to one row, and the row is only
  listed when the total across all printings is fewer than 4. The
  display holding shows the printing the player owns the most of.

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

  @playset 4
  @rarities ~w(mythic rare uncommon common)
  @rarity_priority %{"mythic" => 0, "rare" => 1, "uncommon" => 2, "common" => 3}

  @spec from_holdings([Holding.t()], Snapshot.t()) :: t()
  def from_holdings(holdings, %Snapshot{} = snapshot) when is_list(holdings) do
    rows =
      holdings
      |> Enum.reject(&basic_land?/1)
      |> Enum.group_by(& &1.card.name)
      |> Enum.flat_map(&build_row/1)
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

  # Collapses every printing of a card name into one row. The total
  # count drives `copies_needed`; the holding shown is the printing the
  # player owns the most of, so they recognise the card. Returns `[]`
  # when the player is already at a playset by name (so the caller can
  # `flat_map` cleanly).
  defp build_row({_name, printings}) do
    total = Enum.reduce(printings, 0, fn h, acc -> acc + h.count end)

    if total >= @playset do
      []
    else
      representative = Enum.max_by(printings, & &1.count)
      [%{holding: representative, copies_needed: @playset - total}]
    end
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
