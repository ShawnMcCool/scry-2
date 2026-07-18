defmodule Scry2.NetDecking.ArchetypeCatalog do
  @moduledoc """
  Pure grouping of scored corpus decks into the tiered archetype catalog
  (UIDR-017). No DB, no side effects.

  Pipeline:
    cluster near-duplicates corpus-wide (`DeckClusters` — variants, ×N) →
    label each cluster by its members' majority archetype_name → group
    clusters by that label → derive group status + aggregates → tier by
    best variant status → order tiers.

  Input items are `%{deck, result, signature_set}` — a corpus deck, its
  `Buildability.Result`, and its nonland card identity (for clustering).

  Clustering before grouping is what lets an archetype adopt its
  unclassified near-duplicates: a list the classifier missed (nil
  archetype_name) that Jaccard-matches a classified list joins that
  archetype's group instead of spawning a synthetic one. Clusters where
  no member is classified become nil-named groups — the caller labels
  them synthetically.

  Output: `%{buildable: [group], craftable: [group], short: [group]}`.
  A group is `%{archetype_name, status, variants, tally, list_count,
  member_decks, best_finish_deck, cheapest_sort_key}`; a variant is
  `%{deck, result, member_decks, count}` (near-identical lists collapsed,
  cheapest member as representative). Variants order buildable → craftable
  → short, best finish then cheapest within a status. Tier order: the
  buildable tier by best finish (cost is degenerate at zero); craftable
  and short cheapest-first — matching the rules stated on the page.
  """

  alias Scry2.NetDecking.Deck
  alias Scry2.NetDecking.DeckClusters
  alias Scry2.NetDecking.Provenance

  @status_rank %{buildable: 0, craftable: 1, short: 2}

  @spec build([map()], float()) :: %{buildable: [map()], craftable: [map()], short: [map()]}
  def build(scored_decks, threshold) do
    groups =
      scored_decks
      |> cluster(threshold)
      |> Enum.group_by(fn variant -> majority_archetype_name(variant.member_decks) end)
      |> Enum.flat_map(fn
        {nil, unclassified_variants} ->
          Enum.map(unclassified_variants, fn variant -> group(nil, [variant]) end)

        {archetype_name, variants} ->
          [group(archetype_name, variants)]
      end)

    %{
      buildable: tier(groups, :buildable, &buildable_order/1),
      craftable: tier(groups, :craftable, &cheapest_order/1),
      short: tier(groups, :short, &cheapest_order/1)
    }
  end

  # The community name a cluster's members carry most often; frequency ties
  # break by name for determinism. Nil when no member is classified.
  defp majority_archetype_name(member_decks) do
    member_decks
    |> Enum.map(& &1.archetype_name)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {name, frequency} -> {frequency, name} end, fn -> nil end)
    |> case do
      {name, _frequency} -> name
      nil -> nil
    end
  end

  # ── Variants: near-duplicate clustering within one group ────────────────

  # Near-identical lists collapse to one variant; the cheapest member
  # represents the cluster, so the variant's result is the best buildability
  # the archetype variant can be had for.
  defp cluster(members, threshold) do
    scored_by_deck_id = Map.new(members, fn scored -> {scored.deck.id, scored} end)

    members
    |> Enum.map(fn scored ->
      %{id: scored.deck.id, set: scored.signature_set, weight: total_cost(scored.result)}
    end)
    |> DeckClusters.group(threshold)
    |> Enum.map(fn cluster ->
      representative = Map.fetch!(scored_by_deck_id, cluster.representative_id)

      %{
        deck: representative.deck,
        result: representative.result,
        member_decks: Enum.map(cluster.member_ids, &Map.fetch!(scored_by_deck_id, &1).deck),
        count: cluster.count
      }
    end)
  end

  # ── Group aggregates ─────────────────────────────────────────────────────

  defp group(archetype_name, variants) do
    ordered_variants = Enum.sort_by(variants, &variant_order/1)
    member_decks = Enum.flat_map(ordered_variants, & &1.member_decks)
    best_variant = List.first(ordered_variants)

    %{
      archetype_name: archetype_name,
      status: best_variant.result.status,
      variants: ordered_variants,
      tally: tally(ordered_variants),
      list_count: length(member_decks),
      member_decks: member_decks,
      best_finish_deck: Provenance.best_finish_deck(member_decks),
      cheapest_sort_key: ordered_variants |> Enum.map(& &1.result.sort_key) |> Enum.min()
    }
  end

  defp variant_order(variant) do
    {Map.fetch!(@status_rank, variant.result.status), finish_key(variant.member_decks),
     variant.result.sort_key}
  end

  defp finish_key(member_decks) when is_list(member_decks) do
    member_decks |> Provenance.best_finish_deck() |> finish_key()
  end

  defp finish_key(nil), do: Provenance.finish_sort_key(%Deck{})
  defp finish_key(%Deck{} = deck), do: Provenance.finish_sort_key(deck)

  defp tally(variants) do
    counts = Enum.frequencies_by(variants, & &1.result.status)

    %{
      buildable: Map.get(counts, :buildable, 0),
      craftable: Map.get(counts, :craftable, 0),
      short: Map.get(counts, :short, 0)
    }
  end

  defp total_cost(result), do: elem(result.sort_key, 4)

  # ── Tier assembly ────────────────────────────────────────────────────────

  defp tier(groups, status, order) do
    groups |> Enum.filter(&(&1.status == status)) |> Enum.sort_by(order)
  end

  defp buildable_order(group), do: {finish_key(group.best_finish_deck), group.cheapest_sort_key}

  defp cheapest_order(group), do: {group.cheapest_sort_key, finish_key(group.best_finish_deck)}
end
