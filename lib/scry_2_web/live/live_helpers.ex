defmodule Scry2Web.LiveHelpers do
  @moduledoc """
  Shared pure functions and LiveView helpers used across multiple
  LiveViews. Imported via `Scry2Web.live_view/0`.

  Contains:
  - PubSub debounce helper (`schedule_reload/2`) per ADR-023
  - Shared display formatters extracted from domain-specific helpers
  """

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
  Returns a human label for a snake_case format string
  (e.g. `"premier_draft"` → `"Premier Draft"`).
  """
  @spec format_label(String.t() | nil) :: String.t()
  def format_label(nil), do: "—"

  def format_label(format) when is_binary(format) do
    format
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
