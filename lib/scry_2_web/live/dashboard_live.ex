defmodule Scry2Web.DashboardLive do
  use Scry2Web, :live_view

  alias Scry2.{Cards, Drafts, Events, Matches, MtgaLogIngestion, Topics}
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2Web.DashboardHelpers, as: Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.matches_updates())
      Topics.subscribe(Topics.drafts_updates())
    end

    {:ok,
     socket
     |> assign(:watcher, %{state: :unknown})
     |> assign(:counts, %{
       matches: 0,
       drafts: 0,
       cards: 0,
       events_by_type: %{},
       total_raw: 0,
       total_domain: 0,
       errors: 0
     })
     |> assign(:unrecognized, %{})
     |> assign(:deferred_with_payloads, %{})
     |> assign(:errors, [])
     |> assign(:reload_timer, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:status, _}, socket) do
    {:noreply, assign(socket, :watcher, MtgaLogIngestion.Watcher.status())}
  end

  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:draft_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    {:noreply, socket |> load_data() |> assign(:reload_timer, nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    player_id = socket.assigns[:active_player_id]

    # Pure function calls — no DB, run first
    known_types = IdentifyDomainEvents.known_event_types()
    deferred_types = IdentifyDomainEvents.deferred_event_types()

    # All DB/GenServer calls are independent — run in parallel
    t_watcher = Task.async(fn -> MtgaLogIngestion.Watcher.status() end)
    t_events_by_type = Task.async(fn -> MtgaLogIngestion.count_by_type() end)
    t_domain_counts = Task.async(fn -> Events.count_by_type() end)
    t_error_count = Task.async(fn -> MtgaLogIngestion.count_errors() end)
    t_matches = Task.async(fn -> Matches.count(player_id: player_id) end)
    t_drafts = Task.async(fn -> Drafts.count(player_id: player_id) end)
    t_cards = Task.async(fn -> Cards.count() end)

    t_deferred =
      Task.async(fn -> MtgaLogIngestion.deferred_types_with_payloads(deferred_types) end)

    watcher = Task.await(t_watcher)
    events_by_type = Task.await(t_events_by_type)
    domain_counts = Task.await(t_domain_counts)
    error_count = Task.await(t_error_count)
    deferred_with_payloads = Task.await(t_deferred)

    total_raw = events_by_type |> Map.values() |> Enum.sum()
    total_domain = domain_counts |> Map.values() |> Enum.sum()

    unrecognized =
      Map.reject(events_by_type, fn {type, _count} -> MapSet.member?(known_types, type) end)

    counts = %{
      matches: Task.await(t_matches),
      drafts: Task.await(t_drafts),
      cards: Task.await(t_cards),
      events_by_type: events_by_type,
      total_raw: total_raw,
      total_domain: total_domain,
      errors: error_count
    }

    socket
    |> assign(:watcher, watcher)
    |> assign(:counts, counts)
    |> assign(:unrecognized, unrecognized)
    |> assign(:deferred_with_payloads, deferred_with_payloads)
    |> assign(:errors, if(error_count > 0, do: MtgaLogIngestion.list_errors(), else: []))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold">Dashboard</h1>

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

      <section class="grid grid-cols-1 gap-4 md:grid-cols-3">
        <.stat_card title="Raw Events" value={@counts.total_raw} />
        <.stat_card title="Domain Events" value={@counts.total_domain} />
        <.stat_card
          title="Errors"
          value={@counts.errors}
          class={if @counts.errors > 0, do: "text-error", else: ""}
        />
      </section>

      <section :if={map_size(@unrecognized) > 0} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <p class="font-semibold">Unrecognized event types</p>
          <p class="text-sm mb-2">
            These MTGA event types have no handler or ignore clause in IdentifyDomainEvents (ADR-020).
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Event type</th>
                  <th class="text-right">Count</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{type, count} <- Helpers.sort_events_by_count(@unrecognized)}>
                  <td><code>{type}</code></td>
                  <td class="text-right tabular-nums">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section :if={map_size(@deferred_with_payloads) > 0} class="alert alert-info">
        <.icon name="hero-light-bulb" class="size-5" />
        <div>
          <p class="font-semibold">Deferred events now have payloads</p>
          <p class="text-sm mb-2">
            These event types were deferred because all prior payloads were empty.
            They now have non-empty data and may be ready for a handler.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Event type</th>
                  <th class="text-right">Count</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{type, count} <- Helpers.sort_events_by_count(@deferred_with_payloads)}>
                  <td><code>{type}</code></td>
                  <td class="text-right tabular-nums">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section :if={@errors != []} class="alert alert-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        <div>
          <p class="font-semibold">Processing errors ({@counts.errors})</p>
          <p class="text-sm mb-2">
            Raw events that failed translation. Check the console drawer for details.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Event type</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={error <- @errors}>
                  <td class="tabular-nums">{error.id}</td>
                  <td><code>{error.event_type}</code></td>
                  <td class="text-sm max-w-md truncate">{error.processing_error}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
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
end
