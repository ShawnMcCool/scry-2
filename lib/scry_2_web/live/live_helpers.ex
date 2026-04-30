defmodule Scry2Web.LiveHelpers do
  @moduledoc """
  Shared pure functions and LiveView helpers used across multiple
  LiveViews. Imported via `Scry2Web.live_view/0`.

  Contains:
  - PubSub debounce helper (`schedule_reload/2`) per ADR-023
  - Shared display formatters extracted from domain-specific helpers
  - Win-rate chart period toggle component
  - Step-series compression for `step: "end"` line charts
  """

  use Phoenix.Component

  @doc """
  Cancel-and-reschedule debounce for PubSub-triggered reloads.

  On each PubSub message, cancel any pending `:reload_data` timer and
  schedule a new one. This collapses N rapid events into one database
  query after a quiet period.

  The LiveView must:
  1. Initialize `:reload_timer` to `nil` in `mount/3`
  2. Handle `{:reload_data}` in `handle_info/2` with a fresh data fetch
     that passes current filter assigns (e.g. `active_player_id`)
  """
  @spec schedule_reload(Phoenix.LiveView.Socket.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  def schedule_reload(socket, delay \\ 500) do
    if timer = socket.assigns[:reload_timer], do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), :reload_data, delay)
    Phoenix.Component.assign(socket, :reload_timer, timer)
  end

  @doc "Formats a UTC datetime for display (e.g. `2026-04-07 14:32`)."
  @spec format_datetime(DateTime.t() | nil) :: String.t()
  def format_datetime(nil), do: "—"

  def format_datetime(%DateTime{} = datetime) do
    "#{pad(datetime.year)}-#{pad(datetime.month)}-#{pad(datetime.day)} #{pad(datetime.hour)}:#{pad(datetime.minute)}"
  end

  @doc """
  Maps an MTGA `format_type` string to a higher-level filter category atom
  used by the matches page. `Traditional` collapses into `:constructed`
  because BO1/BO3 is already a separate filter dimension on that page.
  """
  @spec format_category(String.t() | nil) :: :limited | :constructed | :other
  def format_category("Limited"), do: :limited
  def format_category("Constructed"), do: :constructed
  def format_category("Traditional"), do: :constructed
  def format_category(_), do: :other

  @doc "Human label for a category atom."
  @spec category_label(atom()) :: String.t()
  def category_label(:limited), do: "Limited"
  def category_label(:constructed), do: "Constructed"
  def category_label(:other), do: "Other"

  @doc "URL-safe slug for a category atom."
  @spec category_slug(atom()) :: String.t()
  def category_slug(:limited), do: "limited"
  def category_slug(:constructed), do: "constructed"
  def category_slug(:other), do: "other"

  @doc "Inverse of category_slug/1. Returns nil for unknown values."
  @spec category_from_slug(String.t() | nil) :: :limited | :constructed | :other | nil
  def category_from_slug("limited"), do: :limited
  def category_from_slug("constructed"), do: :constructed
  def category_from_slug("other"), do: :other
  def category_from_slug(_), do: nil

  @doc """
  Returns a human label for a snake_case format string
  (e.g. `"premier_draft"` → `"Premier Draft"`).
  """
  @spec format_label(String.t() | nil) :: String.t()
  def format_label(nil), do: "—"

  def format_label(format) when is_binary(format) do
    if String.contains?(format, "_") do
      format
      |> String.split("_")
      |> Enum.map_join(" ", &String.capitalize/1)
    else
      # Already-formatted strings (contain spaces or uppercase) pass through;
      # single lowercase words get capitalized.
      if format =~ ~r/[A-Z ]/, do: format, else: String.capitalize(format)
    end
  end

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

  @doc "Returns a Tailwind text-color class based on win rate threshold."
  @spec win_rate_class(float() | nil) :: String.t()
  def win_rate_class(nil), do: "text-base-content/40"
  def win_rate_class(rate) when rate >= 55.0, do: "text-emerald-400"
  def win_rate_class(rate) when rate >= 45.0, do: "text-base-content"
  def win_rate_class(_), do: "text-red-400"

  @doc "Returns a Tailwind bg-color class based on win rate threshold (for progress bars)."
  @spec win_rate_bar_class(float() | nil) :: String.t()
  def win_rate_bar_class(nil), do: "bg-base-content/40"
  def win_rate_bar_class(rate) when rate >= 55.0, do: "bg-emerald-400"
  def win_rate_bar_class(rate) when rate >= 45.0, do: "bg-warning"
  def win_rate_bar_class(_), do: "bg-error"

  @doc "Returns a formatted win rate string like '55.3%' or '—' if nil."
  @spec format_win_rate(float() | nil) :: String.t()
  def format_win_rate(nil), do: "—"

  def format_win_rate(rate) do
    if rate == trunc(rate), do: "#{trunc(rate)}%", else: "#{rate}%"
  end

  @doc "Returns a 'NW–ML' record string."
  @spec record_str(integer() | nil, integer() | nil) :: String.t()
  def record_str(nil, _), do: ""
  def record_str(_, nil), do: ""
  def record_str(wins, losses), do: "#{wins}W–#{losses}L"

  @doc """
  Returns JSON-encoded win rate series for the ECharts chart.
  Each data point is `[iso8601_timestamp, win_rate, "NW–ML"]`.

  The same shape works for both rolling-window and cumulative win rate
  data — the chart hook doesn't distinguish.
  """
  @spec cumulative_winrate_series(list()) :: String.t()
  def cumulative_winrate_series(points) do
    points
    |> Enum.map(fn point ->
      [point.timestamp, point.win_rate, "#{point.wins}W–#{point.total - point.wins}L"]
    end)
    |> Jason.encode!()
  end

  # ── Win-rate period toggle ───────────────────────────────────────────

  @winrate_periods [
    {"3d", "3D", 3},
    {"1w", "1W", 7},
    {"2w", "2W", 14},
    {"1m", "1M", 30},
    {"3m", "3M", 90},
    {"all", "All", nil}
  ]
  @winrate_default "2w"

  @doc "Default rolling-window slug for win-rate charts."
  def winrate_default_period, do: @winrate_default

  @doc "List of `{slug, label}` pairs for the period-toggle UI."
  def winrate_period_options do
    Enum.map(@winrate_periods, fn {slug, label, _days} -> {slug, label} end)
  end

  @doc """
  Maps a period slug to a `:days` integer (or nil for all-time).
  Falls back to the default if the slug is unrecognized.
  """
  @spec winrate_period_to_days(String.t() | nil) :: pos_integer() | nil
  def winrate_period_to_days(slug) do
    case Enum.find(@winrate_periods, fn {s, _, _} -> s == slug end) do
      {_, _, days} -> days
      nil -> winrate_period_to_days(@winrate_default)
    end
  end

  @doc """
  Validates a period slug. Returns the slug if recognized, the default
  otherwise. Use this when reading from URL params.
  """
  @spec winrate_period_or_default(String.t() | nil) :: String.t()
  def winrate_period_or_default(slug) do
    if Enum.any?(@winrate_periods, fn {s, _, _} -> s == slug end) do
      slug
    else
      @winrate_default
    end
  end

  @doc """
  Renders the win-rate period toggle as a `join` group of buttons.

  Emits `phx-click` events with the configured event name and
  `phx-value-period` set to the slug. The parent LiveView handles the
  event and pushes a patch to the URL.
  """
  attr :selected, :string, required: true
  attr :phx_click, :string, default: "change_winrate_period"

  def winrate_period_toggle(assigns) do
    assigns = Phoenix.Component.assign(assigns, :options, winrate_period_options())

    ~H"""
    <div class="join">
      <button
        :for={{value, label} <- @options}
        type="button"
        phx-click={@phx_click}
        phx-value-period={value}
        class={[
          "join-item btn btn-xs",
          if(@selected == value, do: "btn-active", else: "btn-ghost")
        ]}
      >
        {label}
      </button>
    </div>
    """
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
  Returns nil for BO1 or missing data.
  """
  @spec match_score(map()) :: String.t() | nil
  def match_score(%{won: won, num_games: num_games})
      when is_boolean(won) and is_integer(num_games) and num_games > 1 do
    if won do
      "2–#{num_games - 2}"
    else
      "#{num_games - 2}–2"
    end
  end

  def match_score(_), do: nil

  @doc """
  Converts an MTGA event name to a human-readable label.
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

  @doc "Formats duration in seconds to a human-readable string like '23m' or '1h 5m'."
  @spec format_duration(integer() | nil) :: String.t()
  def format_duration(nil), do: "—"
  def format_duration(seconds) when seconds < 60, do: "<1m"

  def format_duration(seconds) do
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    remaining_minutes = rem(minutes, 60)

    if hours > 0, do: "#{hours}h #{remaining_minutes}m", else: "#{minutes}m"
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp date_label(date, today, _yesterday) when date == today, do: "Today"
  defp date_label(date, _today, yesterday) when date == yesterday, do: "Yesterday"

  defp date_label(date, _today, _yesterday) do
    "#{month_name(date.month)} #{date.day}"
  end

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

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  Compresses a `[[ts, value], ...]` series for `step: "end"` line charts
  by dropping points whose value equals the previous kept point's value.

  Step charts hold a value flat between data points, so consecutive
  identical values are visually redundant. We keep:

  - the first point (anchor),
  - every point where the value differs from the previous kept point,
  - the last point (so the step extends to the right edge of the data
    range — without it, ECharts stops drawing at the last change).

  Apply per series independently when each series in a multi-series
  chart has its own change cadence (e.g. gold and gems on the economy
  currency chart).

  Do **not** use this on continuous-rate charts (winrate, percentile,
  climb) where intermediate points carry information.
  """
  @spec compress_step_series([[term()]]) :: [[term()]]
  def compress_step_series([]), do: []
  def compress_step_series([_only] = points), do: points

  def compress_step_series(points) do
    changes = Enum.dedup_by(points, fn [_ts, value] -> value end)
    last = List.last(points)
    if List.last(changes) == last, do: changes, else: changes ++ [last]
  end
end
