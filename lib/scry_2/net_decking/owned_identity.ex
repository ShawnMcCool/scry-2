defmodule Scry2.NetDecking.OwnedIdentity do
  @moduledoc """
  Collapses collection ownership across printings onto each deck card's
  representative `arena_id`, keyed by card-name identity.

  Web sources (e.g. MTGO) carry no collector number, so a deck card resolves to
  one of a card's many printing `arena_id`s — possibly not the printing the
  player owns. MTGA treats a playset by card name, so ownership must be summed
  across every printing of that name. The pure `Scry2.NetDecking.Buildability`
  engine stays `arena_id`-keyed; this stage feeds it correctly aggregated
  counts.

  The card-identity rule (downcased, trimmed card name) lives in
  `Scry2.DeckList.identity_key/1`. Note: `identity_key/1` also trims; names
  from `cards_cards` never carry surrounding whitespace, so keys are
  unchanged.

  Pure function — no DB. Inputs:

    * `cards_by_arena_id` — `%{arena_id => %{name: ...}}` for the deck's cards
    * `owned_by_arena_id` — the raw collection snapshot `%{arena_id => count}`
    * `printings`         — `%{downcased_name => [arena_id]}` (from
      `Scry2.Cards.printings_by_name/1`)

  Output: `%{representative_arena_id => total_owned_across_printings}`.
  """

  alias Scry2.DeckList

  @spec owned_by_representative(
          %{optional(integer()) => map()},
          %{optional(integer()) => non_neg_integer()},
          %{optional(String.t()) => [integer()]}
        ) :: %{optional(integer()) => non_neg_integer()}
  def owned_by_representative(cards_by_arena_id, owned_by_arena_id, printings) do
    Map.new(cards_by_arena_id, fn {arena_id, card} ->
      key = DeckList.identity_key(name(card))
      printing_ids = Map.get(printings, key, [arena_id])

      total =
        Enum.reduce(printing_ids, 0, fn id, acc -> acc + Map.get(owned_by_arena_id, id, 0) end)

      {arena_id, total}
    end)
  end

  defp name(%{name: name}) when is_binary(name), do: name
  defp name(_), do: ""
end
