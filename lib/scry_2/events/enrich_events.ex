defmodule Scry2.Events.EnrichEvents do
  @moduledoc """
  Enriches domain events with derived data at ingestion time (ADR-030).

  Called by `IngestRawEvents` after translation but before persistence.
  Each enrichment function takes an event struct and the ingestion state,
  returning the event with additional fields populated.

  This is the single place where card metadata lookups, rank stamping,
  and format inference happen. Projectors receive fully enriched events
  and never need external lookups.
  """

  alias Scry2.Cards
  alias Scry2.Events.{DeckSubmitted, MatchCreated, MulliganOffered}

  @doc """
  Enriches a list of domain events using the current ingestion state.
  """
  def enrich(events, state) when is_list(events) do
    Enum.map(events, &enrich_one(&1, state))
  end

  defp enrich_one(%MatchCreated{} = event, state) do
    {format, format_type} = infer_format(event.event_name)

    rank =
      case format_type do
        "Limited" -> state[:limited_rank]
        "Constructed" -> state[:constructed_rank]
        _ -> state[:constructed_rank] || state[:limited_rank]
      end

    %{event | player_rank: rank, format: format, format_type: format_type}
  end

  defp enrich_one(%MulliganOffered{hand_arena_ids: nil} = event, _state), do: event

  defp enrich_one(%MulliganOffered{hand_arena_ids: []} = event, _state), do: event

  defp enrich_one(%MulliganOffered{hand_arena_ids: arena_ids} = event, _state) do
    cards = lookup_cards(arena_ids)

    land_count = Enum.count(cards, & &1.is_land)

    cmc_distribution =
      cards
      |> Enum.reject(& &1.is_land)
      |> Enum.frequencies_by(fn card -> trunc(card.cmc) end)
      |> Map.new(fn {cmc, count} -> {to_string(cmc), count} end)

    color_distribution =
      cards
      |> Enum.flat_map(fn card ->
        card.colors |> String.split(",", trim: true) |> Enum.map(&color_name/1)
      end)
      |> Enum.frequencies()

    card_names =
      Enum.map(arena_ids, fn arena_id ->
        card = Enum.find(cards, &(&1.arena_id == arena_id))
        {to_string(arena_id), card && card.name}
      end)
      |> Map.new()

    %{
      event
      | land_count: land_count,
        nonland_count: length(arena_ids) - land_count,
        total_cmc: cards |> Enum.reject(& &1.is_land) |> Enum.map(& &1.cmc) |> Enum.sum(),
        cmc_distribution: cmc_distribution,
        color_distribution: color_distribution,
        card_names: card_names
    }
  end

  defp enrich_one(%DeckSubmitted{main_deck: main_deck} = event, _state)
       when is_list(main_deck) do
    deck_colors = compute_deck_colors(main_deck)
    %{event | deck_colors: deck_colors}
  end

  defp enrich_one(event, _state), do: event

  # ── Card metadata helpers ───────────────────────────────────────────

  defp lookup_cards(arena_ids) do
    Enum.map(arena_ids, fn arena_id ->
      mtga = Cards.get_mtga_card(arena_id)
      scryfall = Cards.get_scryfall_by_arena_id(arena_id)

      %{
        arena_id: arena_id,
        name: (mtga && mtga.name) || "Unknown",
        is_land: mtga != nil && land?(mtga.types),
        cmc: (scryfall && scryfall.cmc) || 0.0,
        colors: (mtga && mtga.colors) || ""
      }
    end)
  end

  defp land?(types) when is_binary(types) do
    types |> String.split(",", trim: true) |> Enum.member?("5")
  end

  defp land?(_), do: false

  defp compute_deck_colors(main_deck) do
    main_deck
    |> Enum.flat_map(fn
      %{arena_id: arena_id} -> [arena_id]
      %{"arena_id" => arena_id} -> [arena_id]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn arena_id ->
      case Cards.get_mtga_card(arena_id) do
        %{colors: colors} when is_binary(colors) and colors != "" ->
          colors |> String.split(",", trim: true) |> Enum.map(&color_name/1)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join()
  end

  # ── Format inference ────────────────────────────────────────────────

  defp infer_format(nil), do: {nil, nil}

  defp infer_format(event_name) when is_binary(event_name) do
    cond do
      String.starts_with?(event_name, "QuickDraft") -> {"Quick Draft", "Limited"}
      String.starts_with?(event_name, "PremierDraft") -> {"Premier Draft", "Limited"}
      String.starts_with?(event_name, "TradDraft") -> {"Traditional Draft", "Limited"}
      String.starts_with?(event_name, "BotDraft") -> {"Bot Draft", "Limited"}
      String.starts_with?(event_name, "CompDraft") -> {"Comp Draft", "Limited"}
      String.starts_with?(event_name, "Sealed") -> {"Sealed", "Limited"}
      String.starts_with?(event_name, "Ladder") -> {"Ranked", "Constructed"}
      String.starts_with?(event_name, "Play") -> {"Play", "Constructed"}
      String.contains?(event_name, "Draft") -> {"Draft", "Limited"}
      String.contains?(event_name, "Sealed") -> {"Sealed", "Limited"}
      true -> {event_name, nil}
    end
  end

  # MTGA color enum: 1=W, 2=U, 3=B, 4=R, 5=G
  defp color_name("1"), do: "W"
  defp color_name("2"), do: "U"
  defp color_name("3"), do: "B"
  defp color_name("4"), do: "R"
  defp color_name("5"), do: "G"
  defp color_name(other), do: other
end
