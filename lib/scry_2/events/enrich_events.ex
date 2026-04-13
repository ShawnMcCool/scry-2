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
  alias Scry2.Events.Deck.DeckSubmitted
  alias Scry2.Events.EventName
  alias Scry2.Events.Gameplay.MulliganOffered
  alias Scry2.Events.Match.{GameCompleted, MatchCreated}

  @doc """
  Enriches a list of domain events using the current ingestion state.
  """
  def enrich(events, state) when is_list(events) do
    Enum.map(events, &enrich_one(&1, state))
  end

  defp enrich_one(%MatchCreated{} = event, state) do
    parsed = EventName.parse(event.event_name)

    rank =
      case parsed.format_type do
        "Limited" -> state.session.limited_rank
        "Constructed" -> state.session.constructed_rank
        _ -> state.session.constructed_rank || state.session.limited_rank
      end

    deck_name = state.match.last_deck_name

    %{
      event
      | player_rank: rank,
        format: parsed.format,
        format_type: parsed.format_type,
        deck_name: deck_name
    }
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

  defp enrich_one(%GameCompleted{} = event, state) do
    on_play = state.match.on_play_for_current_game
    %{event | on_play: event.on_play || on_play}
  end

  defp enrich_one(%DeckSubmitted{main_deck: main_deck} = event, state)
       when is_list(main_deck) do
    deck_colors = compute_deck_colors(main_deck)
    game_number = event.game_number || state.match.current_game_number
    %{event | deck_colors: deck_colors, game_number: game_number}
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

  @doc """
  Infers `{format, format_type}` from an MTGA event_name string.

  Delegates to `Scry2.Events.EventName.parse/1` for the actual parsing.
  Returns a `{format, format_type}` tuple for backward compatibility.
  """
  def infer_format(event_name) do
    parsed = EventName.parse(event_name)
    {parsed.format, parsed.format_type}
  end

  @doc """
  Infers a deck's constructed format from an MTGA event_name string.

  Returns a `@valid_deck_formats` value ("Standard", "Historic", etc.)
  or nil when the format can't be determined (drafts, sealed, unknown).
  Used by DeckProjection to backfill nil format when DeckUpdated carried
  an event-type string that was filtered by `normalize_deck_format/1`.
  """
  def infer_deck_format(nil), do: nil

  def infer_deck_format(event_name) when is_binary(event_name) do
    cond do
      String.contains?(event_name, "Historic") -> "Historic"
      String.contains?(event_name, "Alchemy") -> "Alchemy"
      String.contains?(event_name, "Explorer") -> "Explorer"
      String.contains?(event_name, "Timeless") -> "Timeless"
      String.contains?(event_name, "Brawl") -> "Brawl"
      String.contains?(event_name, "Pauper") -> "Pauper"
      # Ladder and Play default to Standard (the current standard format)
      String.starts_with?(event_name, "Ladder") -> "Standard"
      String.starts_with?(event_name, "Traditional_Ladder") -> "Standard"
      String.starts_with?(event_name, "Play") -> "Standard"
      String.starts_with?(event_name, "Traditional_Play") -> "Standard"
      # Limited formats don't have a constructed deck format
      true -> nil
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
