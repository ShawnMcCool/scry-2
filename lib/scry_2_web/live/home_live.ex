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

    socket =
      socket
      |> assign(:page_title, "Home")
      |> assign(:tiles, [])
      |> assign(:tiles_loaded?, false)
      |> load_tiles_async()

    {:ok, socket}
  end

  @impl true
  def handle_info(:insights_recomputed, socket) do
    {:noreply, load_tiles_async(socket)}
  end

  @impl true
  def handle_async(:load_tiles, {:ok, tiles}, socket) when is_list(tiles) do
    {:noreply, assign(socket, tiles: tiles, tiles_loaded?: true)}
  end

  def handle_async(:load_tiles, {:exit, _reason}, socket) do
    # Tile composer crashed — keep showing whatever we had. The next
    # :insights_recomputed broadcast will try again.
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      catch_up_status={@catch_up_status}
      sidebar_collapsed={@sidebar_collapsed}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
      nav_update={@nav_update}
    >
      <div class="space-y-6">
        <header class="flex items-baseline justify-between">
          <h1 class="text-2xl font-beleren">Home</h1>
          <div class="text-xs text-base-content/55">
            {tile_count_label(@tiles, @tiles_loaded?)}
          </div>
        </header>

        <div
          :if={@tiles_loaded? and @tiles == []}
          class="rounded-lg border border-dashed border-base-content/20 p-12 text-center text-base-content/55"
        >
          Nothing to show yet. Play a few matches and the homepage will start filling in.
        </div>

        <div :if={not @tiles_loaded?} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.tile_skeleton :for={_ <- 1..4} />
        </div>

        <div :if={@tiles_loaded? and @tiles != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.tile :for={spec <- @tiles} spec={spec} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Skeleton placeholder matching the tile shape until composers return.
  defp tile_skeleton(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-200/40 border border-base-content/5 min-h-[10rem] animate-pulse" />
    """
  end

  # Compose tiles in a supervised task so mount doesn't block. Uses
  # LiveView's `start_async/3` so the task pid is tracked by the socket
  # (proper Ecto sandbox allowance in tests, automatic cleanup on
  # socket disconnect). On the disconnected (HTTP) mount the render
  # shows skeleton tiles — LiveView re-mounts on socket connect and the
  # task fires then.
  defp load_tiles_async(socket) do
    if connected?(socket) do
      start_async(socket, :load_tiles, fn -> Showcase.tiles_for(:home) end)
    else
      socket
    end
  end

  defp tile_count_label(_, false), do: "loading…"
  defp tile_count_label([], true), do: "no tiles"
  defp tile_count_label([_], true), do: "1 tile"
  defp tile_count_label(tiles, true), do: "#{length(tiles)} tiles"
end
