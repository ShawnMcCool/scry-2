defmodule Scry2.NetDecking.Provenance do
  @moduledoc """
  Pure derivation of competitive-provenance display facts from `Deck`
  provenance fields (UIDR-010). No DB, no side effects.

  Finish semantics: `placement` is the final standing after playoffs —
  ranks 1–8 are absolute playoff results and render as bare ordinals
  ("1st"); deeper ranks only mean anything against the field and render
  as "14th of 42". `swiss_rank` is the fallback when an event published
  standings but no final ranks. Absent data yields nil — never a
  placeholder.
  """

  alias Scry2.NetDecking.Deck

  @playoff_size 8

  @doc ~s(Finish for one deck: "1st", "14th of 42", "9th of 42", or nil.)
  @spec finish_label(Deck.t()) :: String.t() | nil
  def finish_label(%Deck{placement: placement} = deck) when is_integer(placement) do
    if placement <= @playoff_size do
      ordinal(placement)
    else
      with_field(ordinal(placement), deck.field_size)
    end
  end

  def finish_label(%Deck{swiss_rank: swiss_rank} = deck) when is_integer(swiss_rank) do
    with_field(ordinal(swiss_rank), deck.field_size)
  end

  def finish_label(%Deck{}), do: nil

  @doc ~s(W-L record: "7-2", or nil unless both sides are known.)
  @spec record_label(Deck.t()) :: String.t() | nil
  def record_label(%Deck{wins: wins, losses: losses})
      when is_integer(wins) and is_integer(losses),
      do: "#{wins}-#{losses}"

  def record_label(%Deck{}), do: nil

  @doc """
  The deck holding a cluster's best finish: lowest placement, else lowest
  swiss rank; nil when no member carries rank data. The tile subtitle shows
  this deck's finish, event, and date.
  """
  @spec best_finish_deck([Deck.t()]) :: Deck.t() | nil
  def best_finish_deck(decks) do
    decks
    |> Enum.reject(fn deck -> is_nil(deck.placement) and is_nil(deck.swiss_rank) end)
    |> Enum.min_by(&finish_sort_key/1, fn -> nil end)
  end

  @doc "Decks ordered best finish first: placements, then swiss-only, then unranked."
  @spec sort_by_finish([Deck.t()]) :: [Deck.t()]
  def sort_by_finish(decks), do: Enum.sort_by(decks, &finish_sort_key/1)

  @doc """
  Ascending sort key: placed decks before swiss-only before unranked.
  Compose with a secondary key (e.g. wildcard cost) for tie-breaking.
  """
  @spec finish_sort_key(Deck.t()) :: {0 | 1 | 2, integer()}
  def finish_sort_key(%Deck{placement: placement}) when is_integer(placement),
    do: {0, placement}

  def finish_sort_key(%Deck{swiss_rank: swiss_rank}) when is_integer(swiss_rank),
    do: {1, swiss_rank}

  def finish_sort_key(%Deck{}), do: {2, 0}

  defp with_field(label, field_size) when is_integer(field_size),
    do: "#{label} of #{field_size}"

  defp with_field(label, _field_size), do: label

  defp ordinal(number) do
    suffix =
      if rem(number, 100) in 11..13 do
        "th"
      else
        case rem(number, 10) do
          1 -> "st"
          2 -> "nd"
          3 -> "rd"
          _ -> "th"
        end
      end

    "#{number}#{suffix}"
  end
end
