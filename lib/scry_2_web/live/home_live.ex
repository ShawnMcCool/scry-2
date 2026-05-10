defmodule Scry2Web.HomeLive do
  @moduledoc """
  The new homepage at `/`. Renders the Curator-style 4-tile exhibit
  composed by `Scry2.Showcase`. Re-renders when insights are recomputed.

  Thin LiveView per ADR-013 — wiring only. Tile composition logic lives
  in `Scry2.Showcase`; rendering lives in `Scry2Web.Tile`.
  """

  use Scry2Web, :live_view

  import Scry2Web.Tile

  alias Scry2.Showcase
  alias Scry2.Topics
  alias Scry2Web.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.insights_updates())
    end

    {:ok,
     socket
     |> assign(:page_title, "Home")
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
        <h1 class="text-2xl font-beleren">Home</h1>
        <div class="text-xs text-base-content/55">
          {tile_count_label(@tiles)}
        </div>
      </header>

      <div
        :if={@tiles == []}
        class="rounded-lg border border-dashed border-base-content/20 p-12 text-center text-base-content/55"
      >
        Nothing to show yet. Play a few matches and the homepage will start filling in.
      </div>

      <div :if={@tiles != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.tile :for={spec <- @tiles} spec={spec} />
      </div>
    </div>

    <Layouts.console_mount socket={@socket} />
    """
  end

  defp assign_tiles(socket) do
    assign(socket, :tiles, Showcase.tiles_for(:home))
  end

  defp tile_count_label([]), do: "no tiles"
  defp tile_count_label([_]), do: "1 tile"
  defp tile_count_label(tiles), do: "#{length(tiles)} tiles"
end
