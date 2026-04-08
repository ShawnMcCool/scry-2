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
end
