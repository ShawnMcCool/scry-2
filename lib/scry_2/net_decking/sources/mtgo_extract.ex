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

  Provenance: the same object carries `standings` (swiss rank), `final_rank`
  (standing after playoffs — top 8 hold their playoff placement), `winloss`,
  `starttime`, and `player_count`, all keyed by `loginid`. Each raw deck is
  stamped with `pilot`, `event_name`, `event_date`, `placement` (final rank),
  `swiss_rank`, `field_size`, `wins`, and `losses`; a player missing from a
  lookup gets nil — provenance is only ever what the page published.

  No HTTP, no DB — fully testable from a captured fixture.
  """
  @marker "window.MTGO.decklists.data ="

  @spec raw_decks(String.t(), String.t()) :: [Scry2.NetDecking.Source.raw_deck()]
  def raw_decks(html, source_url) when is_binary(html) do
    with {:ok, json} <- extract_object(html),
         {:ok, %{"decklists" => decklists} = data} when is_list(decklists) <- JSON.decode(json) do
      context = event_context(data)
      Enum.map(decklists, &to_raw_deck(&1, context, source_url))
    else
      _ -> []
    end
  end

  defp event_context(data) do
    %{
      # display_name feeds deck.name (required) and may fall back; event_name
      # is provenance and stays nil unless the page published one (UIDR-010).
      display_name: data["description"] || "MTGO Standard",
      event_name: data["description"],
      event_date: parse_start_date(data["starttime"]),
      field_size: parse_int(get_in(data, ["player_count", "players"])),
      swiss_rank_by_login: rank_lookup(data["standings"], "rank"),
      placement_by_login: rank_lookup(data["final_rank"], "rank"),
      wins_by_login: rank_lookup(data["winloss"], "wins"),
      losses_by_login: rank_lookup(data["winloss"], "losses")
    }
  end

  defp rank_lookup(entries, field) when is_list(entries) do
    Map.new(entries, fn entry -> {entry["loginid"], parse_int(entry[field])} end)
  end

  defp rank_lookup(_entries, _field), do: %{}

  # "2026-06-08 20:00:00.0" → ~D[2026-06-08]
  defp parse_start_date(<<date_part::binary-size(10), _rest::binary>>) do
    case Date.from_iso8601(date_part) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_start_date(_), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

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

  defp to_raw_deck(decklist, context, source_url) do
    main = lines(decklist["main_deck"])
    side = lines(decklist["sideboard_deck"] || decklist["sideboard"])
    player = decklist["player"] || "Unknown"
    login_id = decklist["loginid"]

    text =
      (["Deck"] ++ main ++ ["", "Sideboard"] ++ side)
      |> Enum.join("\n")

    %{
      name: "#{context.display_name} — #{player}",
      decklist_text: text,
      archetype: nil,
      source_url: source_url,
      pilot: player,
      event_name: context.event_name,
      event_date: context.event_date,
      placement: Map.get(context.placement_by_login, login_id),
      swiss_rank: Map.get(context.swiss_rank_by_login, login_id),
      field_size: context.field_size,
      wins: Map.get(context.wins_by_login, login_id),
      losses: Map.get(context.losses_by_login, login_id)
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
