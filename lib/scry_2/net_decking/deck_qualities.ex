defmodule Scry2.NetDecking.DeckQualities do
  @moduledoc """
  Pure derivation of a netdeck's display qualities from its maindeck cards:
  color identity, the signature (hero + secondary) cards, the canonical
  color-combo name, and the deck's newest set. No DB, no side effects — the
  caller supplies `card_entries` (`[%{arena_id, count}]`) and a
  `%{arena_id => %Card{}}` lookup.
  """

  @combos %{
    "" => "Colorless",
    "W" => "Mono-White",
    "U" => "Mono-Blue",
    "B" => "Mono-Black",
    "R" => "Mono-Red",
    "G" => "Mono-Green",
    "WU" => "Azorius",
    "WB" => "Orzhov",
    "WR" => "Boros",
    "WG" => "Selesnya",
    "UB" => "Dimir",
    "UR" => "Izzet",
    "UG" => "Simic",
    "BR" => "Rakdos",
    "BG" => "Golgari",
    "RG" => "Gruul",
    "WUB" => "Esper",
    "WUR" => "Jeskai",
    "WUG" => "Bant",
    "WBR" => "Mardu",
    "WBG" => "Abzan",
    "WRG" => "Naya",
    "UBR" => "Grixis",
    "UBG" => "Sultai",
    "URG" => "Temur",
    "BRG" => "Jund"
  }

  @doc "Canonical name for a WUBRG-ordered color string (e.g. \"WR\" -> \"Boros\")."
  @spec color_combo_name(String.t()) :: String.t()
  def color_combo_name(colors) when is_binary(colors) do
    case Map.get(@combos, colors) do
      nil -> "#{String.length(colors)}-color"
      name -> name
    end
  end

  @wubrg ~w(W U B R G)

  @doc "WUBRG-ordered color string for the deck's maindeck (e.g. \"WR\"; \"\" = colorless)."
  @spec deck_color_identity([map()], %{optional(integer()) => map()}) :: String.t()
  def deck_color_identity(card_entries, cards) do
    letters =
      card_entries
      |> Enum.flat_map(fn %{arena_id: id} ->
        case Map.get(cards, id) do
          %{color_identity: ci} when is_binary(ci) -> String.graphemes(ci)
          _ -> []
        end
      end)
      |> MapSet.new()

    @wubrg |> Enum.filter(&MapSet.member?(letters, &1)) |> Enum.join()
  end

  @rarity_rank %{"mythic" => 4, "rare" => 3, "uncommon" => 2, "common" => 1}

  @doc "Top-n nonland arena_ids by rarity, then mana value, then arena_id. Hero = first."
  @spec signature_arena_ids([map()], %{optional(integer()) => map()}, pos_integer()) :: [
          integer()
        ]
  def signature_arena_ids(card_entries, cards, n) do
    card_entries
    |> Enum.map(fn %{arena_id: id} -> {id, Map.get(cards, id)} end)
    |> Enum.reject(fn {_id, card} -> is_nil(card) or land?(card) end)
    |> Enum.sort_by(fn {id, card} -> {rarity_rank(card), mana_value(card), id} end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {id, _card} -> id end)
  end

  @doc """
  The archetype's signature cards — "the cards this archetype plays that
  others don't" (UIDR-017). Ranks the group's nonland cards by average copies
  per member list, discounted by how many other archetype groups play the
  card; rarity, then arena_id break ties. `member_entries` is one
  `card_entries` list per member deck; `groups_playing` maps arena_id to the
  number of archetype groups (this one included) whose decks play it.
  Hero = first. A replaceable heuristic — noisy on a thin corpus.
  """
  @spec archetype_signature_ids(
          [[map()]],
          %{optional(integer()) => map()},
          %{optional(integer()) => pos_integer()},
          pos_integer()
        ) :: [integer()]
  def archetype_signature_ids([], _cards, _groups_playing, _n), do: []

  def archetype_signature_ids(member_entries, cards, groups_playing, n) do
    list_count = length(member_entries)

    member_entries
    |> List.flatten()
    |> Enum.reduce(%{}, fn %{arena_id: id, count: count}, copies_by_id ->
      Map.update(copies_by_id, id, count, &(&1 + count))
    end)
    |> Enum.map(fn {id, copies} -> {id, Map.get(cards, id), copies} end)
    |> Enum.reject(fn {_id, card, _copies} -> is_nil(card) or land?(card) end)
    |> Enum.sort_by(
      fn {id, card, copies} ->
        {distinctiveness(copies, list_count, Map.get(groups_playing, id, 1)), rarity_rank(card),
         id}
      end,
      :desc
    )
    |> Enum.take(n)
    |> Enum.map(fn {id, _card, _copies} -> id end)
  end

  # Average copies per list, discounted by play in other archetype groups.
  defp distinctiveness(copies, list_count, groups_playing_count) do
    other_groups = max(groups_playing_count - 1, 0)
    copies / list_count / (1 + other_groups)
  end

  @doc """
  The archetype's typical list (UIDR-017): every card present in at least
  `presence_threshold` of the member lists, at its modal copy count (ties
  resolve to the higher count). `member_entries` is one `card_entries` list
  per member deck. Lands included — the core is the whole typical deck.
  """
  @spec archetype_core([[map()]], float()) :: [%{arena_id: integer(), count: pos_integer()}]
  def archetype_core([], _presence_threshold), do: []

  def archetype_core(member_entries, presence_threshold) do
    list_count = length(member_entries)

    member_entries
    |> List.flatten()
    |> Enum.group_by(& &1.arena_id, & &1.count)
    |> Enum.filter(fn {_arena_id, counts} ->
      length(counts) / list_count >= presence_threshold
    end)
    |> Enum.map(fn {arena_id, counts} -> %{arena_id: arena_id, count: modal_count(counts)} end)
  end

  # Most common copy count; a frequency tie resolves to the higher count.
  defp modal_count(counts) do
    counts
    |> Enum.frequencies()
    |> Enum.max_by(fn {count, frequency} -> {frequency, count} end)
    |> elem(0)
  end

  @doc """
  A variant's differences from the archetype core: `[%{arena_id, delta}]`
  for every card whose copy count differs (absent counts as zero), sorted
  additions first (largest delta down to the deepest cut).
  """
  @spec core_deltas([map()], [map()]) :: [%{arena_id: integer(), delta: integer()}]
  def core_deltas(variant_entries, core_entries) do
    variant_counts = Map.new(variant_entries, fn %{arena_id: id, count: count} -> {id, count} end)
    core_counts = Map.new(core_entries, fn %{arena_id: id, count: count} -> {id, count} end)

    [Map.keys(variant_counts), Map.keys(core_counts)]
    |> Enum.concat()
    |> Enum.uniq()
    |> Enum.map(fn arena_id ->
      %{
        arena_id: arena_id,
        delta: Map.get(variant_counts, arena_id, 0) - Map.get(core_counts, arena_id, 0)
      }
    end)
    |> Enum.reject(fn %{delta: delta} -> delta == 0 end)
    |> Enum.sort_by(fn %{delta: delta, arena_id: arena_id} -> {-delta, arena_id} end)
  end

  @doc "Code of the newest set (by released_at) contributing >=2 of the deck's cards; nil if none."
  @spec newest_set_code([map()], %{optional(integer()) => map()}, %{optional(integer()) => map()}) ::
          String.t() | nil
  def newest_set_code(card_entries, cards, sets) do
    card_entries
    |> Enum.map(fn %{arena_id: id} -> Map.get(cards, id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies_by(& &1.set_id)
    |> Enum.filter(fn {_set_id, count} -> count >= 2 end)
    |> Enum.map(fn {set_id, _count} -> Map.get(sets, set_id) end)
    |> Enum.reject(fn set -> is_nil(set) or is_nil(set.released_at) end)
    |> Enum.sort_by(& &1.released_at, {:desc, Date})
    |> case do
      [%{code: code} | _] -> code
      [] -> nil
    end
  end

  defp land?(%{is_land: true}), do: true
  defp land?(_), do: false
  defp rarity_rank(%{rarity: r}), do: Map.get(@rarity_rank, r, 0)
  defp rarity_rank(_), do: 0
  defp mana_value(%{mana_value: mv}) when is_number(mv), do: mv
  defp mana_value(_), do: 0
end
