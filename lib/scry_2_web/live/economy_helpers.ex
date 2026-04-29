defmodule Scry2Web.EconomyHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.EconomyLive`. Extracted per ADR-013.
  """

  @doc "Formats a currency amount with a label (e.g. '1,500 Gold')."
  @spec format_currency(integer() | nil, String.t()) :: String.t()
  def format_currency(nil, _label), do: "—"
  def format_currency(amount, label), do: "#{format_number(amount)} #{label}"

  @doc "Formats a signed delta (e.g. '+500', '-200')."
  @spec format_delta(integer() | nil) :: String.t()
  def format_delta(nil), do: "—"
  def format_delta(0), do: "0"
  def format_delta(amount) when amount > 0, do: "+#{format_number(amount)}"
  def format_delta(amount), do: format_number(amount)

  @doc "Returns a color class for a delta value."
  @spec delta_class(integer() | nil) :: String.t()
  def delta_class(nil), do: "text-base-content/50"
  def delta_class(amount) when amount > 0, do: "text-emerald-400"
  def delta_class(amount) when amount < 0, do: "text-red-400"
  def delta_class(_), do: "text-base-content/50"

  @doc """
  Returns the net result for an event entry as a list of `{amount_text, currency_type, color_class}` parts.

  The entry fee is subtracted from the matching currency, and any reward
  in the other currency is shown as pure gain. Each part is independently colored.

  `currency_type` is `"Gold"`, `"Gems"`, or `nil` (for status text like "In progress").
  """
  @spec roi_parts(map()) :: [{String.t(), String.t() | nil, String.t()}]
  def roi_parts(%{claimed_at: nil}), do: [{"In progress", nil, "text-amber-400"}]

  def roi_parts(%{
        entry_fee: fee,
        entry_currency_type: type,
        gold_awarded: gold,
        gems_awarded: gems
      })
      when is_integer(fee) do
    {gold_net, gems_net} =
      case type do
        t when t in ["Gold", "gold"] -> {(gold || 0) - fee, gems || 0}
        t when t in ["Gem", "Gems", "gem", "gems"] -> {gold || 0, (gems || 0) - fee}
        _ -> {0, 0}
      end

    {primary, secondary} =
      case type do
        t when t in ["Gold", "gold"] ->
          {if(gold_net != 0, do: {format_delta(gold_net), "Gold", delta_class(gold_net)}),
           if(gems_net != 0, do: {format_delta(gems_net), "Gems", delta_class(gems_net)})}

        _ ->
          {if(gems_net != 0, do: {format_delta(gems_net), "Gems", delta_class(gems_net)}),
           if(gold_net != 0, do: {format_delta(gold_net), "Gold", delta_class(gold_net)})}
      end

    case Enum.reject([primary, secondary], &is_nil/1) do
      [] -> [{"0", nil, "text-base-content/50"}]
      parts -> parts
    end
  end

  def roi_parts(_), do: [{"—", nil, "text-base-content/50"}]

  @month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "Delegates to `Scry2.Economy.parse_event_name/1`."
  defdelegate format_event_name(name), to: Scry2.Economy, as: :parse_event_name

  @doc "Formats a datetime as a short date (e.g. 'Apr 11')."
  @spec format_short_date(DateTime.t() | nil) :: String.t()
  def format_short_date(nil), do: "—"

  def format_short_date(%DateTime{} = datetime) do
    month = Enum.at(@month_names, datetime.month - 1)
    "#{month} #{datetime.day}"
  end

  @doc "Formats an integer with comma separators."
  @spec format_number(integer()) :: String.t()
  def format_number(n) when is_integer(n) and n < 0, do: "-" <> format_number(-n)

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  # ── Chart series builders ─────────────────────────────────────────

  @doc """
  Builds gold and gems time series from inventory snapshots.

  Returns `%{gold: [[iso8601, int], ...], gems: [[iso8601, int], ...]}`.
  """
  @spec currency_series([map()]) :: %{gold: list(), gems: list()}
  def currency_series(snapshots) do
    %{
      gold: Enum.map(snapshots, &[DateTime.to_iso8601(&1.occurred_at), &1.gold || 0]),
      gems: Enum.map(snapshots, &[DateTime.to_iso8601(&1.occurred_at), &1.gems || 0])
    }
  end

  @doc """
  Builds wildcard time series from inventory snapshots.

  Returns `%{common: [...], uncommon: [...], rare: [...], mythic: [...]}`.
  """
  @spec wildcards_series([map()]) :: %{
          common: list(),
          uncommon: list(),
          rare: list(),
          mythic: list()
        }
  def wildcards_series(snapshots) do
    %{
      common:
        Enum.map(snapshots, &[DateTime.to_iso8601(&1.occurred_at), &1.wildcards_common || 0]),
      uncommon:
        Enum.map(snapshots, &[DateTime.to_iso8601(&1.occurred_at), &1.wildcards_uncommon || 0]),
      rare: Enum.map(snapshots, &[DateTime.to_iso8601(&1.occurred_at), &1.wildcards_rare || 0]),
      mythic:
        Enum.map(snapshots, &[DateTime.to_iso8601(&1.occurred_at), &1.wildcards_mythic || 0])
    }
  end

  @doc """
  Filters snapshots to a time range for chart display.

  - `"season"` — returns all snapshots (no filtering)
  - `"2w"` — returns only snapshots from the last 14 days
  - `"week"` — returns only snapshots from the last 7 days
  - `"3d"` — returns only snapshots from the last 3 days
  - `"today"` — returns only snapshots from the current calendar day (UTC)
  """
  @spec filter_snapshots_to_range([map()], String.t()) :: [map()]
  def filter_snapshots_to_range(snapshots, "season"), do: snapshots

  def filter_snapshots_to_range(snapshots, "today") do
    today = Date.utc_today()
    Enum.filter(snapshots, &(DateTime.to_date(&1.occurred_at) == today))
  end

  def filter_snapshots_to_range(snapshots, "3d"), do: filter_by_days(snapshots, 3)
  def filter_snapshots_to_range(snapshots, "week"), do: filter_by_days(snapshots, 7)
  def filter_snapshots_to_range(snapshots, "2w"), do: filter_by_days(snapshots, 14)

  defp filter_by_days(snapshots, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    Enum.filter(snapshots, &(DateTime.compare(&1.occurred_at, cutoff) != :lt))
  end
end
