defmodule Scry2.NetDecking.CompositionKey do
  @moduledoc """
  Content identity of a netdeck's known card list — the dedup key for the
  NetDecking corpus.

  The identity covers everything the ingestion funnel knows about the list:
  the resolved maindeck (`{arena_id, count}` pairs) plus every unresolved
  reference, normalized to a case-folded name with counts summed across
  printings (MTGO splits one card over several set/printing lines within a
  single list). Entry order, printing splits, and name casing never change
  the key, so the same list fetched twice — or pasted twice — always lands
  on the same corpus row.

  The key is the SHA-256 hex digest of a canonical string, so two different
  card lists sharing a key is not a practical concern — which is what makes
  the `(composition_key, format)` unique index on `netdecking_decks` sound
  at any corpus size. `nil` when the composition is empty (nothing resolved,
  nothing unresolved).

  Both inputs use the stored string-keyed map shapes (`main_deck["cards"]`
  and `unresolved_cards["cards"]`), so the key is recomputable from a
  persisted row as well as at ingest time.

  Canonicalization runs through the shared kernel `Scry2.DeckList`: entry
  parsing (`entries/1`) and printing-summed pairs (`canonical_pairs/2`) for
  the resolved side, and the case-folding card-identity rule
  (`identity_key/1`) for the unresolved side.
  """

  alias Scry2.DeckList

  @spec compute([map()], [map()]) :: String.t() | nil
  def compute(main_cards, unresolved_cards)
      when is_list(main_cards) and is_list(unresolved_cards) do
    case resolved_lines(main_cards) ++ unresolved_lines(unresolved_cards) do
      [] ->
        nil

      lines ->
        :sha256
        |> :crypto.hash(Enum.join(lines, "\n"))
        |> Base.encode16(case: :lower)
    end
  end

  defp resolved_lines(main_cards) do
    main_cards
    |> DeckList.entries()
    |> DeckList.canonical_pairs(%{})
    |> Enum.map(fn {arena_id, count} -> "arena:#{arena_id}=#{count}" end)
  end

  defp unresolved_lines(unresolved_cards) do
    unresolved_cards
    |> Enum.flat_map(fn reference ->
      name = reference["name"]
      count = reference["count"]

      if is_binary(name) and is_integer(count) do
        [{DeckList.identity_key(name), count}]
      else
        []
      end
    end)
    |> sum_counts()
    |> Enum.map(fn {name, count} -> "name:#{name}=#{count}" end)
  end

  defp sum_counts(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {key, counts} -> {key, Enum.sum(counts)} end)
    |> Enum.sort()
  end
end
