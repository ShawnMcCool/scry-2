defmodule Scry2Web.DecksHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DecksLive`. Extracted per ADR-013.
  """

  # ── Card grid layout ───────────────────────────────────────────────
  #
  # Two layout modes for the deck card grid:
  #
  # **Compact** — columns are `flex: 1`, cards are `w-full`. Sizing is
  # fully responsive via CSS aspect-ratio + percentage offsets. No JS
  # needed to calculate card dimensions.
  #
  # **Large** — columns have fixed max widths (366px = 75% of 488px
  # native), cards use rem-based absolute positioning.

  # Each overlapped card reveals 25% of its height.
  @visible_fraction 0.25

  # Fixed-rem values for large mode (w-28 = 7rem)
  @card_height_rem 7.0 * (680 / 488)
  @visible_slice_rem @card_height_rem * @visible_fraction

  @doc "Visible portion (rem) of each overlapped card in large mode."
  @spec card_visible_slice() :: float()
  def card_visible_slice, do: Float.round(@visible_slice_rem, 2)

  @doc "Total height (rem) for an absolutely-positioned stack of `n` cards (large mode)."
  @spec card_stack_height(non_neg_integer()) :: float()
  def card_stack_height(0), do: 0.0
  def card_stack_height(n), do: Float.round((n - 1) * @visible_slice_rem + @card_height_rem, 2)

  @doc """
  CSS aspect-ratio value for a responsive card stack container (compact mode).

  Returns a string like `"488 / 850.0"` that scales the container height
  proportionally to its width, so the stack looks correct at any card size.
  """
  @spec card_stack_aspect_ratio(non_neg_integer()) :: String.t()
  def card_stack_aspect_ratio(0), do: "1"
  def card_stack_aspect_ratio(1), do: "488 / 680"

  def card_stack_aspect_ratio(n) do
    height_factor = (n - 1) * @visible_fraction + 1.0
    "488 / #{Float.round(680 * height_factor, 1)}"
  end

  @doc """
  Top offset as a percentage of the stack container height (compact mode).

  Card at index 0 → 0%, subsequent cards are spaced by the visible fraction.
  """
  @spec card_top_percent(non_neg_integer(), pos_integer()) :: float()
  def card_top_percent(0, _n), do: 0.0

  def card_top_percent(index, n) do
    height_factor = (n - 1) * @visible_fraction + 1.0
    Float.round(index * @visible_fraction / height_factor * 100, 2)
  end

  # ── Display formatting ─────────────────────────────────────────────

  @doc "Returns the deck_colors string for mana pip rendering."
  @spec deck_colors(map()) :: String.t()
  def deck_colors(%{deck_colors: colors}) when is_binary(colors), do: colors
  def deck_colors(_), do: ""

  @doc "Returns a relative time string from a UTC datetime."
  @spec relative_time(DateTime.t() | nil) :: String.t()
  def relative_time(nil), do: "—"

  def relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d ago"
      true -> format_date(dt)
    end
  end

  @doc "Returns a human-readable date string from a UTC datetime."
  @spec format_date(DateTime.t() | nil) :: String.t()
  def format_date(nil), do: "—"

  def format_date(dt) do
    date = DateTime.to_date(dt)
    "#{date.year}-#{pad(date.month)}-#{pad(date.day)}"
  end

  @doc "Returns a Tailwind text-color class based on win rate."
  @spec win_rate_class(float() | nil) :: String.t()
  def win_rate_class(nil), do: "text-base-content/40"
  def win_rate_class(rate) when rate >= 55.0, do: "text-emerald-400"
  def win_rate_class(rate) when rate >= 45.0, do: "text-base-content"
  def win_rate_class(_), do: "text-red-400"

  @doc "Returns a formatted win rate string like '55.3%' or '—' if nil. Trims '.0' for whole numbers."
  @spec format_win_rate(float() | nil) :: String.t()
  def format_win_rate(nil), do: "—"

  def format_win_rate(rate) do
    if rate == trunc(rate) do
      "#{trunc(rate)}%"
    else
      "#{rate}%"
    end
  end

  @doc "Returns a 'NW–ML' record string."
  @spec record_str(integer(), integer()) :: String.t()
  def record_str(nil, _), do: ""
  def record_str(_, nil), do: ""
  def record_str(wins, losses), do: "#{wins}W–#{losses}L"

  @doc "Returns a card name by arena_id from the cards lookup map, or a fallback."
  @spec card_name(integer() | nil, map()) :: String.t()
  def card_name(nil, _), do: "Unknown"

  def card_name(arena_id, cards_by_arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      nil -> "#{arena_id}"
      card -> card.name
    end
  end

  # ── Card grouping ─────────────────────────────────────────────────

  @doc """
  Groups the deck's current main deck cards by type, resolving names from
  the cards lookup. Returns a list of `{type_label, [%{count, name, arena_id}]}`.
  """
  @spec group_deck_cards(map(), map()) :: [{String.t(), list()}]
  def group_deck_cards(deck, cards_by_arena_id) do
    cards =
      case deck.current_main_deck do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    cards
    |> Enum.map(fn card ->
      arena_id = card["arena_id"] || card[:arena_id]
      count = card["count"] || card[:count] || 1
      card_data = Map.get(cards_by_arena_id, arena_id)
      type = card_type_label(card_data)
      mana_value = (card_data && card_data.mana_value) || 99

      %{
        arena_id: arena_id,
        count: count,
        name: card_name(arena_id, cards_by_arena_id),
        type: type,
        mana_value: mana_value
      }
    end)
    |> Enum.sort_by(&{type_order(&1.type), &1.mana_value, &1.name})
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {type, _} -> type_order(type) end)
  end

  @doc """
  Returns a JSON-encoded series for the mana curve ECharts bar chart.
  Lands are excluded. Format: `[[cmc_label, count], ...]`
  """
  @spec mana_curve_series(map(), map()) :: String.t()
  def mana_curve_series(deck, cards_by_arena_id) do
    cards =
      case deck.current_main_deck do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    curve =
      cards
      |> Enum.flat_map(fn card ->
        arena_id = card["arena_id"] || card[:arena_id]
        count = card["count"] || card[:count] || 1
        card_data = Map.get(cards_by_arena_id, arena_id)

        if land?(card_data) do
          []
        else
          mv = min((card_data && card_data.mana_value) || 0, 7)
          List.duplicate(mv, count)
        end
      end)
      |> Enum.frequencies()

    0..7
    |> Enum.map(fn mv ->
      label = if mv >= 7, do: "7+", else: "#{mv}"
      [label, Map.get(curve, mv, 0)]
    end)
    |> Jason.encode!()
  end

  @doc """
  Groups the deck's current main deck cards by CMC for visual display.
  Returns `[{cmc_label, [%{arena_id, name, count}]}]` sorted CMC 0–7+, then Lands last.
  """
  @spec group_cards_by_cmc(map(), map()) :: [{String.t(), list()}]
  def group_cards_by_cmc(deck, cards_by_arena_id) do
    cards =
      case deck.current_main_deck do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    cards
    |> Enum.map(fn card ->
      arena_id = card["arena_id"] || card[:arena_id]
      count = card["count"] || card[:count] || 1
      card_data = Map.get(cards_by_arena_id, arena_id)
      cmc_key = card_cmc(card_data)

      %{
        arena_id: arena_id,
        count: count,
        name: card_name(arena_id, cards_by_arena_id),
        cmc_key: cmc_key
      }
    end)
    |> Enum.sort_by(&{&1.cmc_key, &1.name})
    |> Enum.group_by(& &1.cmc_key)
    |> Enum.map(fn {cmc_key, group_cards} -> {cmc_label(cmc_key), group_cards} end)
    |> Enum.sort_by(fn {_, [first | _]} -> first.cmc_key end)
  end

  @doc """
  Returns sideboard cards as a flat list sorted by mana value then name, for horizontal display.
  Each entry is `%{arena_id, count, name, mana_value}`.
  """
  @spec sideboard_cards(map(), map()) :: [
          %{
            arena_id: integer(),
            count: integer(),
            name: String.t(),
            mana_value: non_neg_integer()
          }
        ]
  def sideboard_cards(deck, cards_by_arena_id) do
    case deck.current_sideboard do
      %{"cards" => card_list} ->
        card_list
        |> Enum.map(fn card ->
          arena_id = card["arena_id"] || card[:arena_id]
          count = card["count"] || card[:count] || 1
          card_data = Map.get(cards_by_arena_id, arena_id)
          mana_value = (card_data && card_data.mana_value) || 99

          %{
            arena_id: arena_id,
            count: count,
            name: card_name(arena_id, cards_by_arena_id),
            mana_value: mana_value
          }
        end)
        |> Enum.sort_by(&{&1.mana_value, &1.name})

      _ ->
        []
    end
  end

  @doc """
  Returns main deck card groups (by type) plus a Sideboard column if present.
  Each entry is `{type_label, [%{arena_id, count, name, ...}]}`.
  """
  @spec card_list_with_sideboard(map(), map()) :: [{String.t(), list()}]
  def card_list_with_sideboard(deck, cards_by_arena_id) do
    main = group_deck_cards(deck, cards_by_arena_id)
    sideboard = sideboard_cards(deck, cards_by_arena_id)
    if sideboard == [], do: main, else: main ++ [{"Sideboard", sideboard}]
  end

  @doc """
  Returns JSON-encoded cumulative win rate series for the ECharts chart.
  Each data point is `[iso8601_timestamp, win_rate, "NW–ML"]`.
  """
  @spec cumulative_winrate_series(list()) :: String.t()
  def cumulative_winrate_series(points) do
    series =
      Enum.map(points, fn point ->
        [point.timestamp, point.win_rate, "#{point.wins}W–#{point.total - point.wins}L"]
      end)

    Jason.encode!(series)
  end

  # ── Version timeline helpers ────────────────────────────────────────

  @doc """
  Returns a human-readable datetime string like "April 10, 2026 — 1:01 PM".
  """
  @spec format_version_date(DateTime.t() | nil) :: String.t()
  def format_version_date(nil), do: "—"

  def format_version_date(dt) do
    date = DateTime.to_date(dt)
    month = month_name(date.month)
    hour = rem(if(dt.hour == 0, do: 12, else: dt.hour), 12)
    hour = if hour == 0, do: 12, else: hour
    ampm = if dt.hour < 12, do: "AM", else: "PM"
    "#{month} #{date.day}, #{date.year} — #{hour}:#{pad(dt.minute)} #{ampm}"
  end

  @doc """
  Computes mana curve data for a version's before/after comparison.
  Returns `[{cmc_label, before_count, after_count}]` for CMC 1–7+.

  `previous_version` is the preceding version (or nil for the initial version).
  `cards_by_arena_id` is needed to look up mana values.
  """
  @spec version_mana_curve_data(map(), map() | nil, map()) :: [{String.t(), integer(), integer()}]
  def version_mana_curve_data(version, previous_version, cards_by_arena_id) do
    after_curve = deck_mana_curve(version.main_deck, cards_by_arena_id)

    before_curve =
      if previous_version,
        do: deck_mana_curve(previous_version.main_deck, cards_by_arena_id),
        else: after_curve

    1..7
    |> Enum.map(fn mv ->
      label = if mv >= 7, do: "7+", else: "#{mv}"
      {label, Map.get(before_curve, mv, 0), Map.get(after_curve, mv, 0)}
    end)
  end

  @doc "Extracts arena_ids from a deck version's diff card lists."
  @spec diff_arena_ids(map()) :: [integer()]
  def diff_arena_ids(version) do
    [
      version.main_deck_added,
      version.main_deck_removed,
      version.sideboard_added,
      version.sideboard_removed
    ]
    |> Enum.flat_map(fn
      %{"cards" => cards} -> Enum.map(cards, &((&1["arena_id"] || &1[:arena_id]) |> to_int()))
      _ -> []
    end)
  end

  @doc "Extracts arena_ids from a version's full deck snapshot."
  @spec version_arena_ids(map()) :: [integer()]
  def version_arena_ids(version) do
    [version.main_deck, version.sideboard]
    |> Enum.flat_map(fn
      %{"cards" => cards} -> Enum.map(cards, &((&1["arena_id"] || &1[:arena_id]) |> to_int()))
      _ -> []
    end)
  end

  @doc "Parses a version's diff field into a list of `%{arena_id, count}` maps."
  @spec parse_diff_cards(map() | nil) :: [%{arena_id: integer(), count: integer()}]
  def parse_diff_cards(nil), do: []
  def parse_diff_cards(%{"cards" => []}), do: []

  def parse_diff_cards(%{"cards" => cards}) do
    Enum.map(cards, fn card ->
      %{
        arena_id: (card["arena_id"] || card[:arena_id]) |> to_int(),
        count: (card["count"] || card[:count]) |> to_int()
      }
    end)
    |> Enum.sort_by(& &1.arena_id)
  end

  def parse_diff_cards(_), do: []

  @doc "Returns total card count from a deck snapshot map."
  @spec deck_card_count(map() | nil) :: integer()
  def deck_card_count(nil), do: 0

  def deck_card_count(%{"cards" => cards}),
    do: Enum.sum(Enum.map(cards, &((&1["count"] || &1[:count] || 1) |> to_int())))

  def deck_card_count(_), do: 0

  # ── Match display helpers ────────────────────────────────────────────

  @doc """
  Groups a chronologically-sorted list of matches under date labels.
  Returns `[{label, [match, ...]}]` where label is "Today", "Yesterday",
  or a formatted date like "April 10".
  """
  @spec group_matches_by_date(list()) :: [{String.t(), list()}]
  def group_matches_by_date([]), do: []

  def group_matches_by_date(matches) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    matches
    |> Enum.group_by(fn match ->
      case match.started_at do
        nil -> "Unknown"
        dt -> date_label(DateTime.to_date(dt), today, yesterday)
      end
    end)
    |> Enum.sort_by(fn {_label, [first | _]} -> first.started_at end, {:desc, DateTime})
  end

  @doc """
  Converts an MTGA event name to a human-readable label.
  Combines the inferred event format with the deck's format when applicable.
  """
  @spec humanize_event(String.t() | nil, String.t() | nil) :: String.t()
  def humanize_event(nil, _deck_format), do: "—"

  def humanize_event(event_name, deck_format) do
    case Scry2.Events.EnrichEvents.infer_format(event_name) do
      {"Ranked", _} -> "Ranked #{deck_format || "Constructed"}"
      {"Ranked BO3", _} -> "Ranked #{deck_format || "Constructed"}"
      {"Play", _} -> "Play #{deck_format || "Constructed"}"
      {"Play BO3", _} -> "Play BO3 #{deck_format || "Constructed"}"
      {"Direct Challenge", _} -> "Direct Challenge"
      {format, "Limited"} -> format
      {format, _} -> format
    end
  end

  @doc """
  Extracts per-game details from a match's game_results map.
  Returns a list of `%{won, on_play, num_mulligans}` sorted by game number.
  """
  @spec format_game_results(map() | nil) :: list()
  def format_game_results(nil), do: []

  def format_game_results(%{"results" => results}) when is_list(results) do
    results
    |> Enum.sort_by(& &1["game"])
    |> Enum.map(fn game ->
      %{
        won: game["won"],
        on_play: game["on_play"],
        num_mulligans: game["num_mulligans"] || 0
      }
    end)
  end

  def format_game_results(_), do: []

  @doc """
  Returns a match score string like '2–1' for BO3 matches.
  Uses the match-level `won` and `num_games` fields since per-game
  `won` values in game_results may reflect the opponent's perspective.
  Returns nil for BO1 (single game) or missing data.
  """
  @spec match_score(map()) :: String.t() | nil
  def match_score(%{won: won, num_games: num_games})
      when is_boolean(won) and is_integer(num_games) and num_games > 1 do
    if won do
      losses = num_games - 2
      "2–#{losses}"
    else
      wins = num_games - 2
      "#{wins}–2"
    end
  end

  def match_score(_), do: nil

  # ── Private ─────────────────────────────────────────────────────────

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)
  defp to_int(_), do: 0

  defp month_name(1), do: "January"
  defp month_name(2), do: "February"
  defp month_name(3), do: "March"
  defp month_name(4), do: "April"
  defp month_name(5), do: "May"
  defp month_name(6), do: "June"
  defp month_name(7), do: "July"
  defp month_name(8), do: "August"
  defp month_name(9), do: "September"
  defp month_name(10), do: "October"
  defp month_name(11), do: "November"
  defp month_name(12), do: "December"

  defp date_label(date, today, _yesterday) when date == today, do: "Today"
  defp date_label(date, _today, yesterday) when date == yesterday, do: "Yesterday"
  defp date_label(date, _today, _yesterday), do: "#{month_name(date.month)} #{date.day}"

  # Returns mana curve as %{cmc => total_count} excluding lands.
  defp deck_mana_curve(deck_map, cards_by_arena_id) do
    cards =
      case deck_map do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    Enum.reduce(cards, %{}, fn card, acc ->
      arena_id = (card["arena_id"] || card[:arena_id]) |> to_int()
      count = (card["count"] || card[:count] || 1) |> to_int()
      card_data = Map.get(cards_by_arena_id, arena_id)

      if land?(card_data) do
        acc
      else
        mv = min((card_data && card_data.mana_value) || 0, 7)
        Map.update(acc, mv, count, &(&1 + count))
      end
    end)
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp land?(nil), do: false
  defp land?(card_data), do: String.contains?(card_data.types || "", "Land")

  # CMC key: integer 0–7 for spells (7 = "7+"), 8 for lands (sort last)
  defp card_cmc(nil), do: 0

  defp card_cmc(card_data),
    do: if(land?(card_data), do: 8, else: min(card_data.mana_value || 0, 7))

  defp cmc_label(8), do: "Land"
  defp cmc_label(7), do: "7+"
  defp cmc_label(n), do: "#{n}"

  defp card_type_label(nil), do: "Unknown"

  defp card_type_label(card) do
    types = card.types || ""

    cond do
      String.contains?(types, "Creature") -> "Creatures"
      String.contains?(types, "Planeswalker") -> "Planeswalkers"
      String.contains?(types, "Instant") -> "Instants"
      String.contains?(types, "Sorcery") -> "Sorceries"
      String.contains?(types, "Enchantment") -> "Enchantments"
      String.contains?(types, "Artifact") -> "Artifacts"
      String.contains?(types, "Land") -> "Lands"
      true -> "Other"
    end
  end

  defp type_order("Creatures"), do: 0
  defp type_order("Planeswalkers"), do: 1
  defp type_order("Instants"), do: 2
  defp type_order("Sorceries"), do: 3
  defp type_order("Enchantments"), do: 4
  defp type_order("Artifacts"), do: 5
  defp type_order("Lands"), do: 6
  defp type_order(_), do: 7
end
