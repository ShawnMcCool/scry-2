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

  @doc "Formats an event entry's net result (prize - cost) in the entry currency."
  @spec format_roi(map()) :: String.t()
  def format_roi(%{claimed_at: nil}), do: "In progress"

  def format_roi(%{
        entry_fee: fee,
        entry_currency_type: type,
        gold_awarded: gold,
        gems_awarded: gems
      })
      when is_integer(fee) do
    case type do
      t when t in ["Gold", "gold"] -> format_delta((gold || 0) - fee) <> " Gold"
      t when t in ["Gem", "Gems", "gem", "gems"] -> format_delta((gems || 0) - fee) <> " Gems"
      _ -> "—"
    end
  end

  def format_roi(_), do: "—"

  @month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "Delegates to `Scry2.Economy.parse_event_name/1`."
  defdelegate format_event_name(name), to: Scry2.Economy, as: :parse_event_name

  @doc """
  Returns a text color class based on ROI outcome.

  - `"text-emerald-400"` — positive ROI (profit)
  - `"text-red-400"` — negative ROI (loss)
  - `"text-amber-400"` — in progress (not yet claimed)
  """
  @spec roi_color_class(map()) :: String.t()
  def roi_color_class(%{claimed_at: nil}), do: "text-amber-400"

  def roi_color_class(%{
        entry_fee: fee,
        entry_currency_type: type,
        gold_awarded: gold,
        gems_awarded: gems
      })
      when is_integer(fee) do
    net =
      case type do
        t when t in ["Gold", "gold"] -> (gold || 0) - fee
        t when t in ["Gem", "Gems", "gem", "gems"] -> (gems || 0) - fee
        _ -> 0
      end

    if net >= 0, do: "text-emerald-400", else: "text-red-400"
  end

  def roi_color_class(_), do: "text-amber-400"

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
  - `"week"` — returns only snapshots from the last 7 days
  - `"today"` — returns only snapshots from the current calendar day (UTC)
  """
  @spec filter_snapshots_to_range([map()], String.t()) :: [map()]
  def filter_snapshots_to_range(snapshots, "season"), do: snapshots

  def filter_snapshots_to_range(snapshots, "today") do
    today = Date.utc_today()
    Enum.filter(snapshots, &(DateTime.to_date(&1.occurred_at) == today))
  end

  def filter_snapshots_to_range(snapshots, "week") do
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
    Enum.filter(snapshots, &(DateTime.compare(&1.occurred_at, cutoff) != :lt))
  end
end
