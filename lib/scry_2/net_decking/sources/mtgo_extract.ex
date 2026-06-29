defmodule Scry2.NetDecking.Sources.MtgoExtract do
  @moduledoc """
  Pure HTML → `[raw_deck]` for mtgo.com decklist pages.

  mtgo.com server-renders `window.MTGO.decklists.data = {…};` — a single JSON
  object holding every player's deck for the event. We extract that object by
  brace-balancing (a JSON string may contain `;` or `}`, so a naive cut to the
  first `;` is wrong), JSON-decode it, and emit one `raw_deck` per player deck.

  Each card object carries `qty` at the top level and the card name under
  `card_attributes.card_name`; MTGO supplies no collector number, so
  `decklist_text` is name-only MTGA lines (`<qty> <card_name>`). Resolution
  falls to case-insensitive name match — every current-Standard card exists on
  Arena by name, and `Scry2.Cards.resolve_references/1` handles double-faced
  names via its front-face fallback.

  No HTTP, no DB — fully testable from a captured fixture.
  """
  @marker "window.MTGO.decklists.data ="

  @spec raw_decks(String.t(), String.t()) :: [Scry2.NetDecking.Source.raw_deck()]
  def raw_decks(html, source_url) when is_binary(html) do
    with {:ok, json} <- extract_object(html),
         {:ok, %{"decklists" => decklists} = data} when is_list(decklists) <- JSON.decode(json) do
      event = data["description"] || "MTGO Standard"
      Enum.map(decklists, &to_raw_deck(&1, event, source_url))
    else
      _ -> []
    end
  end

  defp extract_object(html) do
    case :binary.match(html, @marker) do
      :nomatch ->
        :error

      {start, len} ->
        rest = binary_part(html, start + len, byte_size(html) - start - len)
        balance(rest)
    end
  end

  defp balance(str) do
    case :binary.match(str, "{") do
      :nomatch ->
        :error

      {pos, _} ->
        sub = binary_part(str, pos, byte_size(str) - pos)
        scan(String.to_charlist(sub), 0, false, false, [])
    end
  end

  # Walk the charlist tracking brace depth, JSON string state, and escapes.
  # Returns the substring from the opening `{` to its matching `}`.
  defp scan([], _depth, _in_string?, _escaped?, _acc), do: :error

  defp scan([char | rest], depth, in_string?, escaped?, acc) do
    acc = [char | acc]

    cond do
      escaped? -> scan(rest, depth, in_string?, false, acc)
      in_string? and char == ?\\ -> scan(rest, depth, in_string?, true, acc)
      char == ?" -> scan(rest, depth, not in_string?, false, acc)
      in_string? -> scan(rest, depth, in_string?, false, acc)
      char == ?{ -> scan(rest, depth + 1, in_string?, false, acc)
      char == ?} and depth == 1 -> {:ok, acc |> Enum.reverse() |> List.to_string()}
      char == ?} -> scan(rest, depth - 1, in_string?, false, acc)
      true -> scan(rest, depth, in_string?, false, acc)
    end
  end

  defp to_raw_deck(decklist, event, source_url) do
    main = lines(decklist["main_deck"])
    side = lines(decklist["sideboard_deck"] || decklist["sideboard"])
    player = decklist["player"] || "Unknown"

    text =
      (["Deck"] ++ main ++ ["", "Sideboard"] ++ side)
      |> Enum.join("\n")

    %{
      name: "#{event} — #{player}",
      decklist_text: text,
      archetype: nil,
      source_url: source_url
    }
  end

  defp lines(nil), do: []

  defp lines(cards) when is_list(cards) do
    Enum.map(cards, fn card ->
      attrs = card["card_attributes"] || %{}
      name = String.trim(attrs["card_name"] || card["card_name"] || "")
      "#{card["qty"]} #{name}"
    end)
  end
end
