defmodule Scry2.Cards.BasicPrinting do
  @moduledoc """
  The one rule for choosing a card name's canonical display printing:
  the **most basic** printing. Scry2 renders cards, not printings —
  every card image in the app is the basic printing's art, stamped onto
  `cards_cards` at synthesis time (`Scry2.Cards.Synthesize`).

  Basicness is ranked across these axes, most significant first:

  1. Not a flavor-name overlay (Scryfall wraps parody / Universes
     Beyond names in literal double quotes — cosmetic variants, never
     the display printing).
  2. Not a promo.
  3. Not full-art.
  4. Not a variation.
  5. No frame effects (showcase, extended art, …).
  6. Black border (borderless treatments lose).
  7. In draft boosters.
  8. Tiebreaks: numeric collector number ascending (non-numeric last),
     then earliest release, then input order.

  Unknown metadata (nil) ranks as basic — rows imported before the
  treatment columns existed must not be treated as special.
  """

  alias Scry2.Cards.ScryfallCard

  @doc """
  The most basic printing among a name's Scryfall rows, or nil for `[]`.
  Ties keep the earliest element of the input list.
  """
  @spec most_basic([ScryfallCard.t()]) :: ScryfallCard.t() | nil
  def most_basic([]), do: nil
  def most_basic(printings), do: Enum.min_by(printings, &rank/1)

  @doc """
  The sort key ordering printings from most to least basic. Exposed so
  callers can order full lists, not just pick the winner.
  """
  @spec rank(ScryfallCard.t()) :: tuple()
  def rank(printing) do
    {
      special?(flavor_named?(printing)),
      special?(printing.promo == true),
      special?(printing.full_art == true),
      special?(printing.variation == true),
      special?(printing.frame_effects not in [nil, ""]),
      special?(printing.border_color not in [nil, "black"]),
      special?(printing.booster == false),
      collector_rank(printing.collector_number),
      release_rank(printing.released_at)
    }
  end

  @doc """
  Whether a Scryfall row is a flavor-name overlay — the flavor name is
  stored wrapped in literal double quotes.
  """
  @spec flavor_named?(ScryfallCard.t()) :: boolean()
  def flavor_named?(%ScryfallCard{name: name}) when is_binary(name),
    do: String.starts_with?(name, "\"")

  def flavor_named?(_), do: false

  defp special?(true), do: 1
  defp special?(false), do: 0

  # Numeric collector numbers sort ascending; non-numeric forms (e.g.
  # Alchemy "A-58") sort after every numeric one, then lexically.
  defp collector_rank(collector_number) when is_binary(collector_number) do
    case Integer.parse(collector_number) do
      {numeric, _rest} -> {0, numeric, collector_number}
      :error -> {1, 0, collector_number}
    end
  end

  defp collector_rank(nil), do: {2, 0, ""}

  defp release_rank(%Date{} = released_at), do: Date.to_erl(released_at)
  defp release_rank(nil), do: {9999, 12, 31}
end
