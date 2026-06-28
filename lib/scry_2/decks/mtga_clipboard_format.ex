defmodule Scry2.Decks.MtgaClipboardFormat do
  @moduledoc """
  Serialises a `%Scry2.Decks.Deck{}` to MTGA's clipboard-import text format.

  Output is the de-facto standard used by 17lands, Untapped, MTGGoldfish,
  and accepted by MTGA's in-game **Import** button on the deck builder:

      Deck
      4 Lightning Bolt (M21) 162
      3 Counterspell (MH2) 50

      Sideboard
      2 Negate (ZNR) 56

  Pure function — no DB, no side effects. Takes a `Deck` and a lookup map
  of `arena_id => card`, where `card` is either a `%Scry2.Cards.Card{}`
  (with `:collector_number` and a preloaded `:set` association) or any
  map with at least a `:name` key. Missing cards fall back to
  `"<count> #<arena_id>"` so the export is never silently lossy.

  ## Card list shape

  `deck.current_main_deck` and `deck.current_sideboard` are stored as maps
  with a `"cards"` key carrying a list of entries. Each entry may use
  string or atom keys (the wire format uses string keys, but the
  projection sometimes hands struct-shape entries through). Both shapes
  are tolerated.
  """

  alias Scry2.Cards.Card
  alias Scry2.Decks.Deck

  @type card_lookup :: %{optional(integer()) => Card.t() | map()}

  @spec format(Deck.t(), card_lookup()) :: String.t()
  def format(%Deck{} = deck, cards_by_arena_id) when is_map(cards_by_arena_id) do
    format_card_lists(deck.current_main_deck, deck.current_sideboard, cards_by_arena_id)
  end

  @spec format_card_lists(map() | nil, map() | nil, card_lookup()) :: String.t()
  def format_card_lists(main_deck, sideboard, cards_by_arena_id) when is_map(cards_by_arena_id) do
    main = render_section("Deck", main_deck, cards_by_arena_id)
    side = render_section("Sideboard", sideboard, cards_by_arena_id)

    [main, side]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_section(_label, nil, _lookup), do: ""

  defp render_section(label, %{"cards" => cards}, lookup),
    do: render_section(label, cards, lookup)

  defp render_section(label, cards, lookup) when is_list(cards) do
    lines =
      cards
      |> Enum.map(&render_line(&1, lookup))
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> ""
      _ -> [label | lines] |> Enum.join("\n")
    end
  end

  defp render_section(_label, _other, _lookup), do: ""

  defp render_line(entry, lookup) do
    arena_id = entry[:arena_id] || entry["arena_id"]
    count = entry[:count] || entry["count"]

    cond do
      is_nil(arena_id) or is_nil(count) -> nil
      count <= 0 -> nil
      true -> format_line(arena_id, count, Map.get(lookup, arena_id))
    end
  end

  defp format_line(arena_id, count, nil), do: "#{count} ##{arena_id}"

  defp format_line(_arena_id, count, %Card{name: name} = card) do
    set_code = set_code(card)
    collector_number = card.collector_number

    cond do
      is_binary(set_code) and is_binary(collector_number) ->
        "#{count} #{name} (#{String.upcase(set_code)}) #{collector_number}"

      true ->
        "#{count} #{name}"
    end
  end

  defp format_line(_arena_id, count, %{name: name} = card) when is_binary(name) do
    set_code = card[:set_code] || card[:set] |> get_in_set_code()
    collector_number = card[:collector_number]

    cond do
      is_binary(set_code) and is_binary(collector_number) ->
        "#{count} #{name} (#{String.upcase(set_code)}) #{collector_number}"

      true ->
        "#{count} #{name}"
    end
  end

  defp format_line(arena_id, count, _other), do: "#{count} ##{arena_id}"

  defp set_code(%Card{set: %{code: code}}) when is_binary(code), do: code
  defp set_code(_), do: nil

  defp get_in_set_code(%{code: code}) when is_binary(code), do: code
  defp get_in_set_code(_), do: nil
end
