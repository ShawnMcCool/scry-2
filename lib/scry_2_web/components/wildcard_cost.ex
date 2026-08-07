defmodule Scry2Web.WildcardCost do
  @moduledoc """
  How the app shows a wildcard cost or balance: rarity-coloured pips, the
  compact `"2u 1r"` label, and the common→mythic ordering every surface
  uses.

  A cost is the four-rarity map carried by
  `Scry2.Buildability.Section` (`wildcard_cost`, `shortfall`) and by
  `Scry2.Buildability.Assessment` (`wildcards`). Zero rarities never
  render — a cost of nothing is an em dash, not four zeroes.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [wildcard_icon: 1]

  @rarity_order [:common, :uncommon, :rare, :mythic]
  @suffixes [common: "c", uncommon: "u", rare: "r", mythic: "m"]

  @doc """
  Non-zero entries as `{rarity, count}` in common→mythic order — what
  `pips/1` renders.
  """
  @spec pips(map()) :: [{atom(), pos_integer()}]
  def pips(cost) do
    for rarity <- @rarity_order, (count = Map.get(cost, rarity, 0)) > 0, do: {rarity, count}
  end

  @doc "True if a cost map has any non-zero rarity."
  @spec any?(map()) :: boolean()
  def any?(cost), do: pips(cost) != []

  @doc ~s(Compact cost label, e.g. "2u 1r". Returns "—" when zero.)
  @spec format(map()) :: String.t()
  def format(cost) do
    parts =
      for {rarity, suffix} <- @suffixes,
          (count = Map.get(cost, rarity, 0)) > 0,
          do: "#{count}#{suffix}"

    case parts do
      [] -> "—"
      _ -> Enum.join(parts, " ")
    end
  end

  @doc """
  Every rarity as `{rarity, count}` in common→mythic order, zeroes
  included — a balance shows all four, unlike a cost.
  """
  @spec balances(map()) :: [{atom(), non_neg_integer()}]
  def balances(wildcards) do
    Enum.map(@rarity_order, fn rarity -> {rarity, Map.get(wildcards, rarity, 0)} end)
  end

  @doc "A wildcard cost as rarity-coloured pips; an em dash when the cost is zero."
  attr :cost, :map, required: true
  attr :size, :string, default: "size-4"

  def cost_pips(assigns) do
    assigns = assign(assigns, :pips, pips(assigns.cost))

    ~H"""
    <span class="inline-flex items-center gap-2">
      <span :if={@pips == []} class="text-xs text-base-content/40">—</span>
      <span
        :for={{rarity, count} <- @pips}
        class="inline-flex items-center gap-0.5 text-xs text-base-content/70"
      >
        <span class="tabular-nums">{count}</span>
        <.wildcard_icon rarity={Atom.to_string(rarity)} class={@size} />
      </span>
    </span>
    """
  end

  @doc "The player's wildcard pool — all four rarities, zeroes included."
  attr :wildcards, :map, required: true
  attr :size, :string, default: "size-4"

  def balance_row(assigns) do
    assigns = assign(assigns, :balances, balances(assigns.wildcards))

    ~H"""
    <div class="flex items-center gap-3">
      <span
        :for={{rarity, count} <- @balances}
        class="inline-flex items-center gap-1 text-sm text-base-content/70"
      >
        <.wildcard_icon rarity={Atom.to_string(rarity)} class={@size} />
        <span class="tabular-nums">{count}</span>
      </span>
    </div>
    """
  end
end
