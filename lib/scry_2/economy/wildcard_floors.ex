defmodule Scry2.Economy.WildcardFloors do
  @moduledoc """
  Detects when the player's wildcard balances drop at or below sensible
  floor thresholds. Hard-coded defaults — common 50 / uncommon 30 /
  rare 15 / mythic 5 — surface a soft warning on the Economy page so
  the player notices before they craft into a fully-empty rarity.

  Pure functions over an inventory-shaped map. Accepts either an
  `%InventorySnapshot{}` or any map with the four `wildcards_*` keys.
  """

  @rarities [:common, :uncommon, :rare, :mythic]

  @floors %{
    common: 50,
    uncommon: 30,
    rare: 15,
    mythic: 5
  }

  @doc "Returns the default floor for each rarity."
  @spec default_floors() :: %{
          common: pos_integer(),
          uncommon: pos_integer(),
          rare: pos_integer(),
          mythic: pos_integer()
        }
  def default_floors, do: @floors

  @doc """
  Returns the list of rarities at or below their floor, in ascending
  rarity order, with each entry shaped as
  `%{rarity:, count:, floor:}`.

  Returns `[]` for nil inventory or when nothing is below floor.
  """
  @spec below_floor(map() | nil) :: [
          %{rarity: atom(), count: non_neg_integer(), floor: pos_integer()}
        ]
  def below_floor(nil), do: []

  def below_floor(inventory) when is_map(inventory) do
    @rarities
    |> Enum.map(&entry_for(inventory, &1))
    |> Enum.filter(fn %{count: count, floor: floor} -> count <= floor end)
  end

  @doc "True iff any rarity is at or below its floor."
  @spec below_floor?(map() | nil) :: boolean()
  def below_floor?(inventory), do: below_floor(inventory) != []

  @doc "True iff `rarity` is at or below its floor."
  @spec rarity_below?(map() | nil, atom()) :: boolean()
  def rarity_below?(nil, _rarity), do: false

  def rarity_below?(inventory, rarity) when is_map(inventory) and rarity in @rarities do
    %{count: count, floor: floor} = entry_for(inventory, rarity)
    count <= floor
  end

  defp entry_for(inventory, rarity) do
    count = read_count(inventory, rarity)
    floor = Map.fetch!(@floors, rarity)
    %{rarity: rarity, count: count, floor: floor}
  end

  defp read_count(inventory, rarity) do
    key = String.to_existing_atom("wildcards_" <> Atom.to_string(rarity))

    case Map.get(inventory, key) do
      nil -> 0
      n when is_integer(n) -> n
    end
  end
end
