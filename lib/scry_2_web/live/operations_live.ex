defmodule Scry2Web.OperationsLive do
  use Scry2Web, :live_view

  alias Scry2.{Events, Operations, Topics}
  alias Scry2.Events.ProjectorRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.operations())
    end

    {:ok,
     socket
     |> assign(:operation, nil)
     |> assign(:progress, nil)
     |> assign(:reload_timer, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_status(socket)}
  end

  defp load_status(socket) do
    status = Operations.status()
    domain_event_types = Events.count_by_type()
    total_domain = domain_event_types |> Map.values() |> Enum.sum()

    socket
    |> assign(:raw_event_count, status.raw_event_count)
    |> assign(:raw_unprocessed, status.raw_unprocessed)
    |> assign(:domain_event_count, total_domain)
    |> assign(:error_count, status.error_count)
    |> assign(:projectors, status.projectors)
  end

  # ── Events (button clicks) ─────────────────────────────────────────

  @impl true
  def handle_event("rebuild_all", _params, socket) do
    Operations.start_rebuild!()
    {:noreply, socket}
  end

  def handle_event("catch_up_all", _params, socket) do
    Operations.start_catch_up!()
    {:noreply, socket}
  end

  def handle_event("reingest", _params, socket) do
    Operations.start_reingest!()
    {:noreply, socket}
  end

  def handle_event("rebuild_one", %{"module" => module_string}, socket) do
    mod = find_projector_module(module_string)
    if mod, do: Operations.start_rebuild!([mod])
    {:noreply, socket}
  end

  def handle_event("catch_up_one", %{"module" => module_string}, socket) do
    mod = find_projector_module(module_string)
    if mod, do: Operations.start_catch_up!([mod])
    {:noreply, socket}
  end

  defp find_projector_module(name) do
    Enum.find(ProjectorRegistry.all(), fn mod ->
      mod.projector_name() == name
    end)
  end

  # ── PubSub messages (operation progress) ────────────────────────────

  @impl true
  def handle_info({:operation_started, type, metadata}, socket) do
    {:noreply,
     socket
     |> assign(:operation, type)
     |> assign(:progress, Map.put(metadata, :percent, 0))}
  end

  def handle_info({:operation_progress, _type, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info({:operation_completed, type}, socket) do
    {:noreply,
     socket
     |> assign(:operation, nil)
     |> assign(:progress, nil)
     |> put_flash(:info, "#{operation_label(type)} completed.")
     |> load_status()}
  end

  def handle_info({:operation_failed, type, reason}, socket) do
    {:noreply,
     socket
     |> assign(:operation, nil)
     |> assign(:progress, nil)
     |> put_flash(:error, "#{operation_label(type)} failed: #{reason}")
     |> load_status()}
  end

  # Task.Supervisor.async_nolink sends task results back
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:operation, nil)
     |> assign(:progress, nil)
     |> put_flash(:error, "Operation crashed: #{inspect(reason)}")
     |> load_status()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────

  defp operation_label(:reingest), do: "Reingest"
  defp operation_label(:rebuild), do: "Rebuild"
  defp operation_label(:catch_up), do: "Catch up"

  defp busy?(assigns), do: assigns.operation != nil

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp progress_percent(%{percent: p}), do: p
  defp progress_percent(_), do: 0

  defp progress_label(nil), do: ""

  defp progress_label(%{phase: :retranslation, processed: processed, total: total}) do
    "Retranslating: #{format_number(processed)} / #{format_number(total)} raw events"
  end

  defp progress_label(%{
         phase: :projection,
         current_projector: name,
         projector_index: i,
         projector_total: total
       }) do
    "Rebuilding #{name} (#{i}/#{total})"
  end

  defp progress_label(%{projectors: names}) do
    "Starting: #{Enum.join(names, ", ")}"
  end

  defp progress_label(_), do: "Working..."

  defp watermark_percent(_watermark, 0), do: 100
  defp watermark_percent(watermark, max_id), do: round(watermark / max_id * 100)

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold">Operations</h1>

      <%!-- Pipeline overview --%>
      <section class="grid grid-cols-2 gap-4 md:grid-cols-4">
        <.stat_card title="Raw MTGA Events" value={format_number(@raw_event_count)} />
        <.stat_card title="Domain Events" value={format_number(@domain_event_count)} />
        <.stat_card title="Unprocessed" value={format_number(@raw_unprocessed)} />
        <.stat_card
          title="Errors"
          value={format_number(@error_count)}
          class={if @error_count > 0, do: "text-error", else: ""}
        />
      </section>

      <%!-- Active operation banner --%>
      <section :if={@operation} class="alert alert-info">
        <.icon name="hero-arrow-path" class="size-5 animate-spin" />
        <div class="flex-1">
          <p class="font-semibold">{operation_label(@operation)} in progress</p>
          <p class="text-sm opacity-80">{progress_label(@progress)}</p>
          <progress
            class="progress progress-info w-full mt-2"
            value={progress_percent(@progress)}
            max="100"
          >
          </progress>
        </div>
      </section>

      <%!-- Bulk actions --%>
      <section class="flex flex-wrap gap-3">
        <button
          phx-click="rebuild_all"
          disabled={busy?(assigns)}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Rebuild All Projections
        </button>
        <button
          phx-click="catch_up_all"
          disabled={busy?(assigns)}
          class="btn btn-soft btn-sm"
        >
          <.icon name="hero-forward" class="size-4" /> Catch Up All
        </button>
        <button
          phx-click="reingest"
          disabled={busy?(assigns)}
          data-confirm="This will clear all domain events and re-translate from raw MTGA events. Continue?"
          class="btn btn-warning btn-sm"
        >
          <.icon name="hero-arrow-uturn-left" class="size-4" /> Reingest from MTGA Events
        </button>
      </section>

      <%!-- Projections table --%>
      <section>
        <h2 class="text-lg font-semibold mb-3">Projections</h2>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Projector</th>
                <th>Event Types</th>
                <th>Watermark</th>
                <th>Lag</th>
                <th>Progress</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={proj <- @projectors}>
                <td class="font-mono text-sm">{proj.name}</td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={slug <- proj.claimed_slugs}
                      class="badge badge-xs badge-ghost font-mono"
                    >
                      {slug}
                    </span>
                  </div>
                </td>
                <td class="font-mono text-sm">
                  {format_number(proj.watermark)} / {format_number(proj.max_event_id)}
                </td>
                <td>
                  <span class={[
                    "font-mono text-sm",
                    if(proj.lag > 0, do: "text-warning", else: "text-success")
                  ]}>
                    {format_number(proj.lag)}
                  </span>
                </td>
                <td>
                  <progress
                    class={[
                      "progress w-24",
                      if(proj.lag == 0, do: "progress-success", else: "progress-warning")
                    ]}
                    value={watermark_percent(proj.watermark, proj.max_event_id)}
                    max="100"
                  >
                  </progress>
                </td>
                <td class="text-right">
                  <div class="flex gap-1 justify-end">
                    <button
                      phx-click="rebuild_one"
                      phx-value-module={proj.name}
                      disabled={busy?(assigns)}
                      class="btn btn-xs btn-ghost"
                      title={"Rebuild #{proj.name}"}
                    >
                      <.icon name="hero-arrow-path" class="size-3" />
                    </button>
                    <button
                      phx-click="catch_up_one"
                      phx-value-module={proj.name}
                      disabled={busy?(assigns)}
                      class="btn btn-xs btn-ghost"
                      title={"Catch up #{proj.name}"}
                    >
                      <.icon name="hero-forward" class="size-3" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
