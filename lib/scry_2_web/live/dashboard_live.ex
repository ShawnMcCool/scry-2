defmodule Scry2Web.DashboardLive do
  use Scry2Web, :live_view

  alias Scry2.{Cards, Drafts, Matches, MtgaLogs, Topics}
  alias Scry2Web.DashboardHelpers, as: Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.matches_updates())
      Topics.subscribe(Topics.drafts_updates())
      Topics.subscribe(Topics.cards_updates())
    end

    {:ok,
     socket
     |> assign(:watcher, %{state: :unknown})
     |> assign(:counts, %{matches: 0, drafts: 0, cards: 0, events_by_type: %{}})
     |> assign(:refresh_result, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    watcher = MtgaLogs.Watcher.status()

    counts = %{
      matches: Matches.count(),
      drafts: Drafts.count(),
      cards: Cards.count(),
      events_by_type: MtgaLogs.count_by_type()
    }

    {:noreply,
     socket
     |> assign(:watcher, watcher)
     |> assign(:counts, counts)}
  end

  @impl true
  def handle_event("refresh_cards", _params, socket) do
    {:ok, _job} =
      %{}
      |> Scry2.Workers.CardsRefreshWorker.new()
      |> Oban.insert()

    {:noreply,
     socket
     |> put_flash(:info, "Refresh enqueued — reload after a moment.")
     |> assign(:refresh_result, :enqueued)}
  end

  @impl true
  def handle_info({:status, _}, socket) do
    {:noreply, assign(socket, :watcher, MtgaLogs.Watcher.status())}
  end

  def handle_info({:match_updated, _}, socket) do
    {:noreply, assign(socket, :counts, %{socket.assigns.counts | matches: Matches.count()})}
  end

  def handle_info({:draft_updated, _}, socket) do
    {:noreply, assign(socket, :counts, %{socket.assigns.counts | drafts: Drafts.count()})}
  end

  def handle_info({:cards_refreshed, count}, socket) do
    counts = %{socket.assigns.counts | cards: Cards.count()}

    {:noreply,
     socket
     |> assign(:counts, counts)
     |> put_flash(:info, "Imported #{count} cards.")}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Dashboard</h1>
        <button class="btn btn-primary btn-sm" phx-click="refresh_cards">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh cards from 17lands
        </button>
      </div>

      <div :if={Helpers.show_detailed_logs_warning?(@watcher)} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <p class="font-semibold">MTGA Player.log not found.</p>
          <p class="text-sm">
            Enable <em>Detailed Logs (Plugin Support)</em> in MTGA → Options → View Account,
            or set the path in <.link navigate={~p"/settings"} class="link">Settings</.link>.
          </p>
        </div>
      </div>

      <section class="grid grid-cols-1 gap-4 md:grid-cols-4">
        <.stat_card title="Watcher" value={Helpers.watcher_label(@watcher)} />
        <.stat_card title="Matches" value={@counts.matches} />
        <.stat_card title="Drafts" value={@counts.drafts} />
        <.stat_card title="Cards" value={@counts.cards} />
      </section>

      <section :if={map_size(@counts.events_by_type) > 0}>
        <h2 class="text-lg font-semibold mb-2">Log events by type</h2>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Event type</th>
                <th class="text-right">Count</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{type, count} <- Helpers.sort_events_by_count(@counts.events_by_type)}>
                <td><code>{type}</code></td>
                <td class="text-right tabular-nums">{count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4">
        <p class="text-xs uppercase text-base-content/60">{@title}</p>
        <p class="text-2xl font-semibold">{@value}</p>
      </div>
    </div>
    """
  end
end
