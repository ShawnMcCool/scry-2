defmodule Scry2Web.InsightsLive do
  @moduledoc """
  Browse all active insights at `/insights`. Lists every materialized
  active insight grouped by detector, rendered through the same
  Tile component as the homepage.

  Thin wiring per ADR-013 — selection logic lives in `Scry2.Showcase`
  and `Scry2.Insights`, rendering in `Scry2Web.Tile`.
  """

  use Scry2Web, :live_view

  import Scry2Web.Tile

  alias Scry2.Insights
  alias Scry2.Showcase.TileTypes.CoachInsight
  alias Scry2.Topics
  alias Scry2Web.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.insights_updates())
    end

    {:ok,
     socket
     |> assign(:page_title, "Insights")
     |> assign_tiles()}
  end

  @impl true
  def handle_info(:insights_recomputed, socket) do
    {:noreply, assign_tiles(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-beleren">Insights</h1>
        <div class="text-xs text-base-content/55">
          {tile_count_label(@tiles)}
        </div>
      </header>

      <p class="text-sm text-base-content/70 max-w-2xl leading-relaxed">
        Patterns the app noticed in your play. Every measurement shows its sample size
        and confidence — coach voice fires only when a detector earned the right to speak.
      </p>

      <div
        :if={@tiles == []}
        class="rounded-lg border border-dashed border-base-content/20 p-12 text-center text-base-content/55"
      >
        No active insights yet. Run <code>Scry2.Insights.compute_all/0</code> from IEx
        or wait for the daily 06:00 UTC cron pass.
      </div>

      <div :if={@tiles != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.tile :for={spec <- @tiles} spec={spec} />
      </div>
    </div>

    <Layouts.console_mount socket={@socket} />
    """
  end

  defp assign_tiles(socket) do
    tiles =
      :home
      |> Insights.list_active()
      |> Enum.map(&CoachInsight.build/1)

    assign(socket, :tiles, tiles)
  end

  defp tile_count_label([]), do: "no active insights"
  defp tile_count_label([_]), do: "1 active"
  defp tile_count_label(tiles), do: "#{length(tiles)} active"
end
