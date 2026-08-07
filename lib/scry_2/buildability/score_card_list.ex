defmodule Scry2.Buildability.ScoreCardList do
  @moduledoc """
  Stage 2 of the buildability pipeline: the pure rules. Each rule is an
  independently testable function; `score/4` orchestrates them. No DB,
  no PubSub.

  Pipeline (per section):
    card_shortage → rarity_buckets → affordability → (classify_status / sort_key)

  `card_rows/3` is the same shortage arithmetic at per-card granularity —
  the row the UI renders beside each card.

  The "free/infinite" policy (basic lands today) is injected via the
  position's `free_arena_ids`, never hardcoded into a rule.
  """

  alias Scry2.Buildability.CardRow
  alias Scry2.Buildability.CollectionPosition
  alias Scry2.Buildability.Result
  alias Scry2.Buildability.Section
  alias Scry2.DeckList

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

  @doc """
  Scores a maindeck/sideboard pair against the player's position. Both
  accept any card-list snapshot `Scry2.DeckList` understands.

  Status and sort_key derive from the maindeck. A maindeck with any card
  missing from MTGA (`unresolved_count > 0`) is always `:incomplete` — no
  wildcard count fixes a card the client doesn't have, so this gates
  ahead of `classify_status/2` rather than being folded into its
  cost/shortfall math.
  """
  @spec score(CollectionPosition.t(), term(), term(), non_neg_integer()) :: Result.t()
  def score(%CollectionPosition{} = position, main_deck, sideboard, unresolved_count) do
    main = section(DeckList.entries(main_deck), position)
    side = section(DeckList.entries(sideboard), position)

    status =
      if unresolved_count > 0 do
        :incomplete
      else
        classify_status(main.wildcard_cost, main.shortfall)
      end

    %Result{
      status: status,
      maindeck: main,
      sideboard: side,
      sort_key: sort_key(main.wildcard_cost)
    }
  end

  @doc """
  Per-card ownership rows for one card list — what the UI annotates each
  card with. `cards_by_arena_id` supplies the display name.
  """
  @spec card_rows(CollectionPosition.t(), term(), %{optional(integer()) => map()}) :: [
          CardRow.t()
        ]
  def card_rows(%CollectionPosition{} = position, card_list, cards_by_arena_id) do
    card_list
    |> DeckList.entries()
    |> Enum.map(fn %{arena_id: arena_id, count: needed} ->
      free? = MapSet.member?(position.free_arena_ids, arena_id)
      owned = Map.get(position.owned, arena_id, 0)

      %CardRow{
        arena_id: arena_id,
        name: display_name(cards_by_arena_id, arena_id),
        rarity: Map.get(position.rarities, arena_id),
        needed: needed,
        owned: owned,
        missing: if(free?, do: 0, else: max(0, needed - owned)),
        free?: free?
      }
    end)
  end

  defp display_name(cards_by_arena_id, arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      %{name: name} when is_binary(name) -> name
      _other -> "#" <> Integer.to_string(arena_id)
    end
  end

  defp section(cards, %CollectionPosition{} = position) do
    shortages = card_shortage(cards, position.owned, position.free_arena_ids)
    cost = rarity_buckets(shortages, position.rarities)
    shortfall = affordability(cost, position.wildcards)

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
