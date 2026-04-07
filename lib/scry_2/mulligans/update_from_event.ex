defmodule Scry2.Mulligans.UpdateFromEvent do
  @moduledoc """
  Projects domain events into the `mulligans_mulligan_listing` read model.

  ## Claimed domain events

    * `"mulligan_offered"` → upsert a row with hand data
    * `"match_created"` → stamp `event_name` on existing rows for that match

  Mulligan events often arrive before the match_created event (the game
  state messages come first). When match_created arrives, it backfills
  `event_name` on any mulligan rows already written for that match_id.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Cards
  alias Scry2.Events
  alias Scry2.Events.{MatchCreated, MulliganOffered}
  alias Scry2.Matches
  alias Scry2.Mulligans
  alias Scry2.Topics

  @claimed_slugs ~w(mulligan_offered match_created)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.domain_events())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:domain_event, id, type_slug}, state) when type_slug in @claimed_slugs do
    try do
      event = Events.get!(id)
      project(event)
    rescue
      error ->
        Log.error(
          :ingester,
          "mulligans projector failed on domain_event id=#{id} type=#{type_slug}: #{inspect(error)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:domain_event, _id, _type_slug}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp project(%MulliganOffered{} = event) do
    arena_ids = event.hand_arena_ids || []

    # Look up event_name from the matches projection.
    event_name =
      case Matches.get_by_mtga_id(event.mtga_match_id, event.player_id) do
        %{event_name: name} -> name
        _ -> nil
      end

    # Precompute hand stats from card metadata (ADR-027).
    hand_stats = compute_hand_stats(arena_ids)

    attrs =
      %{
        player_id: event.player_id,
        mtga_match_id: event.mtga_match_id,
        event_name: event_name,
        seat_id: event.seat_id,
        hand_size: event.hand_size,
        hand_arena_ids: %{"cards" => arena_ids},
        occurred_at: event.occurred_at
      }
      |> Map.merge(hand_stats)

    Mulligans.upsert_hand!(attrs)
    :ok
  end

  defp project(%MatchCreated{} = event) do
    if event.mtga_match_id && event.event_name do
      Mulligans.stamp_event_name!(event.mtga_match_id, event.event_name)
    end

    :ok
  end

  defp project(_event), do: :ok

  # ── Hand stats computation (ADR-027) ───────────────────────────────

  defp compute_hand_stats([]), do: %{}

  defp compute_hand_stats(arena_ids) do
    cards =
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
      land_count: land_count,
      nonland_count: length(arena_ids) - land_count,
      total_cmc: cards |> Enum.reject(& &1.is_land) |> Enum.map(& &1.cmc) |> Enum.sum(),
      cmc_distribution: cmc_distribution,
      color_distribution: color_distribution,
      card_names: card_names
    }
  end

  # MTGA types enum: "5" = Land. A card with types "1,5" is an artifact land.
  defp land?(types) when is_binary(types) do
    types |> String.split(",", trim: true) |> Enum.member?("5")
  end

  defp land?(_), do: false

  # MTGA color enum: 1=W, 2=U, 3=B, 4=R, 5=G
  defp color_name("1"), do: "W"
  defp color_name("2"), do: "U"
  defp color_name("3"), do: "B"
  defp color_name("4"), do: "R"
  defp color_name("5"), do: "G"
  defp color_name(other), do: other
end
