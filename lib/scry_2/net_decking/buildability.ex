defmodule Scry2.NetDecking.Buildability do
  @moduledoc """
  Pure, modular buildability engine. Each rule is an independently testable
  function; `score/1` orchestrates them. No DB, no PubSub.

  Pipeline (per section):
    card_shortage → rarity_buckets → affordability → (classify_status / sort_key)

  The "free/infinite" policy (basic lands today) is injected as
  `free_arena_ids`, never hardcoded into a rule.
  """

  alias Scry2.NetDecking.Buildability.{Inputs, Result, Section}

  @basic_land_names ~w(Plains Island Swamp Mountain Forest Wastes)
  @rarities [:common, :uncommon, :rare, :mythic]
  @zero %{common: 0, uncommon: 0, rare: 0, mythic: 0}

  @doc "Default free-card policy: arena_ids in `cards_by_arena_id` that are basic lands."
  @spec default_free_ids(%{optional(integer()) => map()}) :: MapSet.t()
  def default_free_ids(cards_by_arena_id) do
    cards_by_arena_id
    |> Enum.filter(fn {_id, card} -> card_name(card) in @basic_land_names end)
    |> Enum.map(fn {id, _card} -> id end)
    |> MapSet.new()
  end

  defp card_name(%{name: name}), do: name
  defp card_name(_), do: nil

  @doc "Per-card missing copies `[{arena_id, missing}]`, excluding free arena_ids and zero-shortage cards."
  @spec card_shortage([map()], map(), MapSet.t()) :: [{integer(), integer()}]
  def card_shortage(cards, owned, free_arena_ids) do
    cards
    |> Enum.reject(fn %{arena_id: id} -> MapSet.member?(free_arena_ids, id) end)
    |> Enum.map(fn %{arena_id: id, count: needed} ->
      {id, max(0, needed - Map.get(owned, id, 0))}
    end)
    |> Enum.reject(fn {_id, missing} -> missing == 0 end)
  end

  @doc "Buckets missing copies by rarity."
  @spec rarity_buckets([{integer(), integer()}], map()) :: Section.rarity_map()
  def rarity_buckets(shortages, rarities) do
    Enum.reduce(shortages, @zero, fn {arena_id, missing}, acc ->
      key = rarity_key(Map.get(rarities, arena_id))
      Map.update!(acc, key, &(&1 + missing))
    end)
  end

  defp rarity_key("common"), do: :common
  defp rarity_key("uncommon"), do: :uncommon
  defp rarity_key("rare"), do: :rare
  defp rarity_key("mythic"), do: :mythic
  # Unknown/nil rarity is treated as rare so it is never silently free.
  defp rarity_key(_), do: :rare

  @doc "Per-rarity shortfall of `cost` against current `wildcards` balances."
  @spec affordability(map(), map()) :: Section.rarity_map()
  def affordability(cost, wildcards) do
    Map.new(@rarities, fn rarity ->
      {rarity, max(0, Map.get(cost, rarity, 0) - Map.get(wildcards, rarity, 0))}
    end)
  end

  @doc "Derives status from total cost and shortfall."
  @spec classify_status(map(), map()) :: Result.status()
  def classify_status(cost, shortfall) do
    cond do
      total(cost) == 0 -> :buildable
      total(shortfall) == 0 -> :craftable
      true -> :short
    end
  end

  defp total(map), do: Enum.reduce(@rarities, 0, fn r, acc -> acc + Map.get(map, r, 0) end)

  @doc "Orderable key: fewer missing mythics/rares/uncommons/commons sorts first; total breaks ties."
  @spec sort_key(map()) :: {integer(), integer(), integer(), integer(), integer()}
  def sort_key(cost) do
    {Map.get(cost, :mythic, 0), Map.get(cost, :rare, 0), Map.get(cost, :uncommon, 0),
     Map.get(cost, :common, 0), total(cost)}
  end

  @doc "Scores a deck against a collection. Status and sort_key derive from the maindeck."
  @spec score(Inputs.t()) :: Result.t()
  def score(%Inputs{} = inputs) do
    main = section(inputs.main_cards, inputs)
    side = section(inputs.side_cards, inputs)
    status = classify_status(main.wildcard_cost, main.shortfall)

    %Result{
      status: status,
      maindeck: main,
      sideboard: side,
      sort_key: sort_key(main.wildcard_cost)
    }
  end

  defp section(cards, %Inputs{} = inputs) do
    shortages = card_shortage(cards, inputs.owned, inputs.free_arena_ids)
    cost = rarity_buckets(shortages, inputs.rarities)
    shortfall = affordability(cost, inputs.wildcards)

    total_copies = Enum.reduce(cards, 0, fn %{count: count}, acc -> acc + count end)
    missing_copies = Enum.reduce(shortages, 0, fn {_id, m}, acc -> acc + m end)

    %Section{
      wildcard_cost: cost,
      shortfall: shortfall,
      owned_pct: owned_pct(total_copies, missing_copies),
      total_copies: total_copies,
      missing_copies: missing_copies
    }
  end

  defp owned_pct(0, _missing), do: 1.0
  defp owned_pct(total, missing), do: Float.round((total - missing) / total, 3)
end
