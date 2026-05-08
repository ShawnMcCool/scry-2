defmodule Scry2.Cards.Synthesize.SetMetadata do
  @moduledoc """
  Extracts per-set metadata (`name`, `released_at`) from the full set of
  Scryfall rows.

  Reads from ALL Scryfall rows, **not** an `arena_id != nil` subset.
  This is the load-bearing distinction that fixes the SOS / TMT / TLA
  case where Scryfall has the cards (and hence the set name + date) but
  hasn't yet backfilled `arena_id` for any of them. See ADR-038.

  `released_at` for a set is the earliest `released_at` across all cards
  in that set, which handles reprints / promo printings that ship later
  than the set's main release date.
  """

  alias Scry2.Cards.ScryfallCard

  @type meta :: %{name: String.t() | nil, released_at: Date.t() | nil}

  @doc """
  Aggregates per-set `%{name, released_at}` from a list of Scryfall rows,
  keyed on `String.upcase(set_code)`. Skips rows with nil/blank set_code.
  """
  @spec extract([ScryfallCard.t()]) :: %{String.t() => meta()}
  def extract(scryfall_rows) when is_list(scryfall_rows) do
    Enum.reduce(scryfall_rows, %{}, fn
      %ScryfallCard{set_code: code} = card, acc when is_binary(code) and code != "" ->
        upper = String.upcase(code)
        existing = Map.get(acc, upper, %{name: nil, released_at: nil})

        Map.put(acc, upper, %{
          name: existing.name || card.set_name,
          released_at: earliest_date(existing.released_at, card.released_at)
        })

      _, acc ->
        acc
    end)
  end

  defp earliest_date(nil, b), do: b
  defp earliest_date(a, nil), do: a
  defp earliest_date(a, b), do: if(Date.compare(a, b) == :lt, do: a, else: b)
end
