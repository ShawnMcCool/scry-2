defmodule Scry2Web.Components.ForecastStrip.Helpers do
  @moduledoc """
  Pure helpers for the forecast strip's display formatting.
  Extracted per ADR-013 so the formatting logic is unit-testable.
  """

  @doc """
  Formats a signed integer with a leading `+` for positives and a
  thin-space thousands separator. Zero renders as `"0"` (no sign).
  """
  @spec format_signed(integer() | float()) :: String.t()
  def format_signed(0), do: "0"

  def format_signed(n) when is_integer(n) and n > 0,
    do: "+#{format_thousands(n)}"

  def format_signed(n) when is_integer(n) and n < 0,
    do: "−#{format_thousands(-n)}"

  def format_signed(n) when is_float(n), do: format_signed(round(n))

  @doc """
  Formats a per-day rate. Rounds to whole units; renders nothing for
  zero. Returns a parenthesised "(±N/day)" string or `""`.
  """
  @spec format_rate_suffix(float()) :: String.t()
  def format_rate_suffix(rate) when is_float(rate) do
    rounded = round(rate)

    cond do
      rounded == 0 -> ""
      rounded > 0 -> " (+#{format_thousands(rounded)}/day)"
      true -> " (−#{format_thousands(-rounded)}/day)"
    end
  end

  @doc """
  Renders the vault ETA result variant as a player-facing string.
  """
  @spec vault_eta_label(
          %{eta: DateTime.t(), days: float(), rate_per_day: float()}
          | :already_full
          | :no_progress
          | :insufficient_data
        ) :: String.t()
  def vault_eta_label(:already_full), do: "Vault full"
  def vault_eta_label(:no_progress), do: "Vault not progressing"
  def vault_eta_label(:insufficient_data), do: "Vault — not enough data"

  def vault_eta_label(%{eta: eta, days: days}) do
    date = eta |> DateTime.to_date() |> Calendar.strftime("%b %-d")

    cond do
      days < 1.0 -> "Vault opens today (#{date})"
      days < 1.5 -> "Vault opens tomorrow (#{date})"
      days < 60.0 -> "Vault opens #{date} (in #{round(days)} days)"
      true -> "Vault opens #{date}"
    end
  end

  defp format_thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end
end

defmodule Scry2Web.Components.ForecastStrip do
  @moduledoc """
  Compact trends row for the Economy page. Shows net change + daily
  rate for gold and gems over the selected time range, plus a vault
  opening ETA.

  Driven by `Scry2.Economy.Forecast` over the same filtered snapshot
  list that feeds the currency and wildcards charts. Hides itself
  when there aren't enough snapshots to estimate.
  """

  use Phoenix.Component

  alias Scry2Web.Components.ForecastStrip.Helpers

  attr :gold_net, :integer, required: true
  attr :gold_rate, :float, required: true
  attr :gems_net, :integer, required: true
  attr :gems_rate, :float, required: true
  attr :vault_eta, :any, required: true
  attr :visible, :boolean, default: true

  def forecast_strip(assigns) do
    ~H"""
    <div
      :if={@visible}
      data-test="forecast-strip"
      class="flex flex-wrap items-center gap-x-6 gap-y-1 text-xs text-base-content/70"
    >
      <span class="inline-flex items-center gap-1">
        <span class="text-base-content/40 uppercase tracking-wide">Gold</span>
        <span class="tabular-nums font-medium">
          {Helpers.format_signed(@gold_net)}{Helpers.format_rate_suffix(@gold_rate)}
        </span>
      </span>
      <span class="inline-flex items-center gap-1">
        <span class="text-base-content/40 uppercase tracking-wide">Gems</span>
        <span class="tabular-nums font-medium">
          {Helpers.format_signed(@gems_net)}{Helpers.format_rate_suffix(@gems_rate)}
        </span>
      </span>
      <span class="inline-flex items-center gap-1">
        <.vault_dot variant={@vault_eta} />
        <span>{Helpers.vault_eta_label(@vault_eta)}</span>
      </span>
    </div>
    """
  end

  attr :variant, :any, required: true

  defp vault_dot(assigns) do
    klass =
      case assigns.variant do
        :already_full -> "bg-success"
        :no_progress -> "bg-warning"
        :insufficient_data -> "bg-base-content/20"
        _ -> "bg-info"
      end

    assigns = assign(assigns, :klass, klass)

    ~H"""
    <span class={"inline-block size-1.5 rounded-full #{@klass}"} />
    """
  end
end
