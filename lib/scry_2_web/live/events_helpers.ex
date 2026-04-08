defmodule Scry2Web.EventsHelpers do
  @moduledoc """
  Pure functions for event display — summaries, categories, badge colors,
  and correlation labels. Extracted per ADR-013 for unit testing.
  """

  alias Scry2.Events.Deck.{DeckInventory, DeckSelected, DeckSubmitted, DeckUpdated}
  alias Scry2.Events.Draft.{DraftPickMade, DraftStarted}
  alias Scry2.Events.Economy.InventoryChanged
  alias Scry2.Events.Event.{EventCourseUpdated, EventJoined, EventRewardClaimed, PairingEntered}
  alias Scry2.Events.Gameplay.MulliganOffered
  alias Scry2.Events.Match.{DieRolled, GameCompleted, MatchCompleted, MatchCreated}
  alias Scry2.Events.Progression.{DailyWinsStatus, MasteryProgress, QuestStatus, RankSnapshot}
  alias Scry2.Events.Session.SessionStarted

  @type event_category :: :match | :draft | :economy | :session | :snapshot

  @doc "Classifies a domain event into a display category."
  @spec event_category(struct()) :: event_category()
  def event_category(%MatchCreated{}), do: :match
  def event_category(%MatchCompleted{}), do: :match
  def event_category(%GameCompleted{}), do: :match
  def event_category(%DeckSubmitted{}), do: :match
  def event_category(%DieRolled{}), do: :match
  def event_category(%MulliganOffered{}), do: :match
  def event_category(%DraftStarted{}), do: :draft
  def event_category(%DraftPickMade{}), do: :draft
  def event_category(%EventJoined{}), do: :economy
  def event_category(%EventRewardClaimed{}), do: :economy
  def event_category(%InventoryChanged{}), do: :economy
  def event_category(%PairingEntered{}), do: :economy
  def event_category(%DeckSelected{}), do: :economy
  def event_category(%SessionStarted{}), do: :session
  def event_category(_), do: :snapshot

  @doc "Returns a Tailwind badge color class for an event category."
  @spec type_badge_color(event_category()) :: String.t()
  def type_badge_color(:match), do: "badge-success"
  def type_badge_color(:draft), do: "badge-info"
  def type_badge_color(:economy), do: "badge-warning"
  def type_badge_color(:session), do: "badge-accent"
  def type_badge_color(:snapshot), do: "badge-ghost"

  @doc """
  One-line human-readable summary for a domain event. Used in list views.
  """
  @spec event_summary(struct()) :: String.t()
  def event_summary(%MatchCreated{} = event) do
    opponent = event.opponent_screen_name || "unknown"
    name = event.event_name || ""
    "vs. #{opponent} — #{name}"
  end

  def event_summary(%MatchCompleted{} = event) do
    result = if event.won, do: "Won", else: "Lost"
    games = if event.num_games, do: " (#{event.num_games} games)", else: ""
    "#{result}#{games}"
  end

  def event_summary(%GameCompleted{} = event) do
    result = if event.won, do: "Won", else: "Lost"
    play = if event.on_play, do: "on play", else: "on draw"
    "Game #{event.game_number} — #{result}, #{play}"
  end

  def event_summary(%DeckSubmitted{} = event) do
    main = length(event.main_deck || [])
    side = length(event.sideboard || [])
    "#{main} cards main, #{side} sideboard"
  end

  def event_summary(%DieRolled{} = event) do
    result = if event.self_goes_first, do: "going first", else: "going second"
    "Roll #{event.self_roll} vs #{event.opponent_roll}, #{result}"
  end

  def event_summary(%MulliganOffered{} = event) do
    cards = if event.hand_arena_ids, do: " (#{length(event.hand_arena_ids)} cards)", else: ""
    "Hand size: #{event.hand_size}#{cards}"
  end

  def event_summary(%DraftStarted{} = event) do
    "#{event.event_name} — #{event.set_code}"
  end

  def event_summary(%DraftPickMade{} = event) do
    "Pack #{event.pack_number}, Pick #{event.pick_number}"
  end

  def event_summary(%EventJoined{} = event) do
    fee = if event.entry_fee, do: " (#{event.entry_fee} #{event.entry_currency_type})", else: ""
    "#{event.event_name}#{fee}"
  end

  def event_summary(%EventRewardClaimed{} = event) do
    "#{event.event_name} — #{event.final_wins || 0}W #{event.final_losses || 0}L"
  end

  def event_summary(%InventoryChanged{} = event) do
    deltas =
      [gold: event.gold_delta, gems: event.gems_delta]
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == 0 end)
      |> Enum.map(fn {k, v} ->
        sign = if v > 0, do: "+", else: ""
        "#{sign}#{v} #{k}"
      end)
      |> Enum.join(", ")

    source = event.source || "unknown"
    if deltas == "", do: source, else: "#{source}: #{deltas}"
  end

  def event_summary(%DeckSelected{} = event) do
    name = event.deck_name || "unnamed"
    "#{name} for #{event.event_name}"
  end

  def event_summary(%PairingEntered{} = event) do
    "Queued for #{event.event_name}"
  end

  def event_summary(%SessionStarted{} = event) do
    event.screen_name || "Session started"
  end

  def event_summary(%RankSnapshot{} = event) do
    "#{event.limited_class} #{event.limited_level} (Limited)"
  end

  def event_summary(%QuestStatus{} = event) do
    count = length(event.quests || [])
    "#{count} active quests"
  end

  def event_summary(%DailyWinsStatus{} = event) do
    "Daily position: #{event.daily_position}"
  end

  def event_summary(%EventCourseUpdated{} = event) do
    "#{event.event_name} — #{event.current_wins || 0}W #{event.current_losses || 0}L"
  end

  def event_summary(%DeckInventory{} = event) do
    count = length(event.decks || [])
    "#{count} decks"
  end

  def event_summary(%DeckUpdated{} = event) do
    action = event.action_type || "updated"
    "#{event.deck_name} — #{action}"
  end

  def event_summary(%MasteryProgress{} = event) do
    "#{event.completed_nodes || 0}/#{event.total_nodes || 0} nodes"
  end

  def event_summary(_event), do: ""

  @doc """
  Returns a short correlation label like "match:a8f3…" for display.
  Picks the most specific correlation available (match > draft > session).
  """
  @spec correlation_label(struct()) :: String.t() | nil
  def correlation_label(event) do
    cond do
      match_id = Map.get(event, :mtga_match_id) ->
        "match:#{truncate_id(match_id)}"

      draft_id = Map.get(event, :mtga_draft_id) ->
        "draft:#{truncate_id(draft_id)}"

      true ->
        nil
    end
  end

  defp truncate_id(id) when is_binary(id) and byte_size(id) > 8 do
    String.slice(id, 0, 8) <> "…"
  end

  defp truncate_id(id) when is_binary(id), do: id
  defp truncate_id(_), do: "?"
end
