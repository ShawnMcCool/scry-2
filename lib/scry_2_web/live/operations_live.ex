defmodule Scry2Web.OperationsLive do
  use Scry2Web, :live_view

  alias Scry2.{Events, MtgaLogIngestion, Operations, Topics}
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.ProjectorRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.operations())
      Topics.subscribe(Topics.domain_control())
      Topics.subscribe(Topics.domain_events())
      Topics.subscribe(Topics.matches_updates())
      Topics.subscribe(Topics.drafts_updates())
    end

    {:ok,
     socket
     |> assign(:operation, nil)
     |> assign(:operation_running, false)
     |> assign(:progress, nil)
     |> assign(:steps, [])
     |> assign(:projector_progress, %{})
     |> assign(:pending_rebuilds, nil)
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

    # Raw-event breakdowns — used by the bottom tables that moved over
    # from the old dashboard.
    raw_events_by_type = MtgaLogIngestion.count_by_type()
    known_types = IdentifyDomainEvents.known_event_types()
    deferred_types = IdentifyDomainEvents.deferred_event_types()

    unrecognized =
      Map.reject(raw_events_by_type, fn {type, _count} -> MapSet.member?(known_types, type) end)

    deferred_with_payloads = MtgaLogIngestion.deferred_types_with_payloads(deferred_types)

    errors =
      if status.error_count > 0, do: MtgaLogIngestion.list_errors(), else: []

    # Restore last operation state so the section survives page reload /
    # WebSocket reconnect. Only applied when no operation is already tracked
    # in assigns (i.e. fresh mount) — live PubSub updates take precedence.
    socket =
      if socket.assigns.operation == nil do
        case Operations.last_operation() do
          nil ->
            socket

          %{type: type, running: false} ->
            socket
            |> assign(:operation, type)
            |> assign(:operation_running, false)
            |> assign(:progress, %{percent: 100})

          %{type: type, running: true} ->
            socket
            |> assign(:operation, type)
            |> assign(:operation_running, true)
        end
      else
        socket
      end

    socket
    |> assign(:raw_event_count, status.raw_event_count)
    |> assign(:raw_unprocessed, status.raw_unprocessed)
    |> assign(:domain_event_count, total_domain)
    |> assign(:error_count, status.error_count)
    |> assign(:projectors, status.projectors)
    |> assign(:raw_events_by_type, raw_events_by_type)
    |> assign(:unrecognized, unrecognized)
    |> assign(:deferred_with_payloads, deferred_with_payloads)
    |> assign(:errors, errors)
  end

  # Orders a `type => count` map by count descending — used by the raw
  # event breakdown tables at the bottom of the page.
  defp sort_events_by_count(map) when is_map(map) do
    Enum.sort_by(map, fn {_type, count} -> count end, :desc)
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
    projector_names = Map.get(metadata, :projectors, [])

    # Reingest has two phases, but projectors now self-manage their rebuild via
    # :full_rebuild on domain:control — there are no progress events for them.
    # Show only Retranslation + a single "Projector rebuilds" placeholder.
    # Rebuild/catch-up operations still show individual projector steps.
    steps =
      if type == :reingest do
        [
          %{name: "Retranslation", status: :pending, detail: nil},
          %{name: "Projector rebuilds (async)", status: :pending, detail: nil}
        ]
      else
        Enum.map(projector_names, &%{name: &1, status: :pending, detail: nil})
      end

    pending_rebuilds =
      if type == :reingest, do: MapSet.new(projector_names), else: nil

    {:noreply,
     socket
     |> assign(:operation, type)
     |> assign(:operation_running, true)
     |> assign(:progress, nil)
     |> assign(:steps, steps)
     |> assign(:projector_progress, %{})
     |> assign(:pending_rebuilds, pending_rebuilds)}
  end

  def handle_info({:operation_progress, _type, %{phase: :retranslation} = progress}, socket) do
    detail = "#{format_number(progress.processed)} / #{format_number(progress.total)} events"

    steps =
      socket.assigns.steps
      |> update_step("Retranslation", :in_progress, detail)
      |> then(fn steps ->
        # When retranslation reaches 100%, mark it done and show projector step as in_progress.
        if progress.percent == 100 do
          steps
          |> update_step("Retranslation", :done, nil)
          |> update_step("Projector rebuilds (async)", :in_progress, "running in background")
        else
          steps
        end
      end)

    {:noreply, socket |> assign(:progress, progress) |> assign(:steps, steps)}
  end

  def handle_info(
        {:operation_progress, _type, %{phase: :projection, projector: name} = progress},
        socket
      ) do
    detail = "#{format_number(progress.processed)} / #{format_number(progress.total)} events"

    # All projectors run concurrently — update only this projector's step.
    # Mark the Retranslation step done when the first projection progress arrives.
    steps =
      Enum.map(socket.assigns.steps, fn
        %{name: "Retranslation", status: :in_progress} = step ->
          %{step | status: :done, detail: nil}

        %{name: ^name} = step ->
          %{step | status: :in_progress, detail: detail}

        step ->
          step
      end)

    # Track per-projector percent so the global bar shows mean completion.
    projector_progress = Map.put(socket.assigns.projector_progress, name, progress.percent)

    global_percent =
      projector_progress
      |> Map.values()
      |> then(fn percents ->
        if percents == [], do: 0, else: div(Enum.sum(percents), length(percents))
      end)

    {:noreply,
     socket
     |> assign(:steps, steps)
     |> assign(:projector_progress, projector_progress)
     |> assign(:progress, %{phase: :projection, percent: global_percent})}
  end

  def handle_info({:operation_progress, _type, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info({:operation_completed, type}, socket) do
    # For reingest: retranslation is done and :full_rebuild has been broadcast to projectors.
    # Keep the "Projector rebuilds" step spinning — it completes when all projectors
    # broadcast {:projector_rebuilt, name} back on domain:control.
    # For rebuild/catch_up: all projectors have already finished (coordinator waited for acks).
    steps =
      if type == :reingest do
        socket.assigns.steps
        |> update_step("Retranslation", :done, nil)
        |> update_step("Projector rebuilds (async)", :in_progress, "waiting for projectors")
      else
        Enum.map(socket.assigns.steps, &%{&1 | status: :done, detail: nil})
      end

    label =
      if type == :reingest,
        do: "Retranslation complete — projectors rebuilding",
        else: "#{operation_label(type)} completed."

    operation_running = type == :reingest

    {:noreply,
     socket
     |> assign(:operation_running, operation_running)
     |> assign(:progress, %{percent: 100})
     |> assign(:steps, steps)
     |> put_flash(:info, label)
     |> load_status()}
  end

  def handle_info({:operation_failed, type, reason}, socket) do
    {:noreply,
     socket
     |> assign(:operation, nil)
     |> assign(:operation_running, false)
     |> assign(:progress, nil)
     |> assign(:steps, [])
     |> put_flash(:error, "#{operation_label(type)} failed: #{reason}")
     |> load_status()}
  end

  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, socket), do: {:noreply, socket}

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:operation, nil)
     |> assign(:progress, nil)
     |> assign(:steps, [])
     |> put_flash(:error, "Operation crashed: #{inspect(reason)}")
     |> load_status()}
  end

  # Projector completion acks from domain:control ─────────────────────

  def handle_info({:projector_rebuilt, name}, socket) do
    socket =
      case socket.assigns.pending_rebuilds do
        nil ->
          socket

        pending ->
          remaining = MapSet.delete(pending, name)

          socket =
            if MapSet.size(remaining) == 0 do
              steps = update_step(socket.assigns.steps, "Projector rebuilds (async)", :done, nil)

              socket
              |> assign(:operation_running, false)
              |> assign(:pending_rebuilds, nil)
              |> assign(:steps, steps)
              |> put_flash(:info, "Reingest complete.")
            else
              assign(socket, :pending_rebuilds, remaining)
            end

          socket
      end

    {:noreply, load_status(socket)}
  end

  def handle_info({:projector_caught_up, _name}, socket) do
    {:noreply, load_status(socket)}
  end

  def handle_info({:projector_progress, _name, _processed, _total}, socket) do
    {:noreply, socket}
  end

  # Domain event and projection updates — debounced reload for stat cards
  def handle_info({:domain_event, _id, _type}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    {:noreply, load_status(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Step tracking helpers ───────────────────────────────────────────

  defp update_step(steps, name, status, detail) do
    Enum.map(steps, fn step ->
      if step.name == name, do: %{step | status: status, detail: detail}, else: step
    end)
  end

  # ── Formatting helpers ─────────────────────────────────────────────

  defp operation_label(:reingest), do: "Reingest"
  defp operation_label(:rebuild), do: "Rebuild"
  defp operation_label(:catch_up), do: "Catch up"

  defp busy?(assigns), do: assigns.operation_running

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

  defp projector_name(assigns) do
    [context, module] = String.split(assigns.name, ".")
    spaced = Regex.replace(~r/(?<=[a-z])(?=[A-Z])/, module, " ")
    assigns = assign(assigns, context: context, module: spaced)

    ~H"""
    {@context}<span class="text-base-content/30 text-xs mx-1">/</span>{@module}
    """
  end

  defp progress_percent(%{percent: p}), do: min(p, 100)
  defp progress_percent(_), do: 0

  defp step_icon(:done), do: "hero-check-circle"
  defp step_icon(:in_progress), do: "hero-arrow-path"
  defp step_icon(:pending), do: "hero-clock"

  defp step_color(:done), do: "text-success"
  defp step_color(:in_progress), do: "text-info"
  defp step_color(:pending), do: "text-base-content/30"

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

      <%!-- Operation progress (shown while running and after completion) --%>
      <section :if={@operation} class="card bg-base-200">
        <div class="card-body p-5">
          <div class="flex items-center gap-2 mb-3">
            <.icon
              :if={@operation_running}
              name="hero-arrow-path"
              class="size-5 text-info animate-spin"
            />
            <.icon
              :if={!@operation_running}
              name="hero-check-circle"
              class="size-5 text-success"
            />
            <h2 class="card-title text-base">
              {if @operation_running,
                do: "#{operation_label(@operation)} in progress",
                else: "#{operation_label(@operation)} complete"}
            </h2>
          </div>

          <progress
            class={[
              "progress w-full mb-4",
              if(@operation_running, do: "progress-info", else: "progress-success")
            ]}
            value={progress_percent(@progress)}
            max="100"
          >
          </progress>

          <ul class="space-y-2">
            <li :for={step <- @steps} class="flex items-center gap-3">
              <.icon
                name={step_icon(step.status)}
                class={[
                  "size-5",
                  step_color(step.status),
                  step.status == :in_progress && "animate-spin"
                ]}
              />
              <span class={[
                "font-mono text-sm",
                if(step.status == :pending, do: "opacity-40", else: "")
              ]}>
                {step.name}
              </span>
              <span :if={step.detail} class="text-xs text-base-content/60">
                {step.detail}
              </span>
            </li>
          </ul>
        </div>
      </section>

      <%!-- Action cards --%>
      <section class="grid grid-cols-1 gap-4 md:grid-cols-3">
        <div class="card bg-base-200">
          <div class="card-body p-5">
            <h3 class="card-title text-base">
              <.icon name="hero-arrow-path" class="size-5" /> Rebuild All Projections
            </h3>
            <p class="text-sm text-base-content/60">
              Truncates all projection tables and replays every domain event from scratch.
              Use after changing projector logic or to fix corrupted state.
            </p>
            <div class="card-actions justify-end mt-2">
              <button
                phx-click="rebuild_all"
                disabled={busy?(assigns)}
                class="btn btn-soft btn-primary btn-sm"
              >
                Rebuild All
              </button>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body p-5">
            <h3 class="card-title text-base">
              <.icon name="hero-forward" class="size-5" /> Catch Up All
            </h3>
            <p class="text-sm text-base-content/60">
              Resumes each projector from its last watermark without truncating.
              Use after a crash or restart to process missed events.
            </p>
            <div class="card-actions justify-end mt-2">
              <button phx-click="catch_up_all" disabled={busy?(assigns)} class="btn btn-soft btn-sm">
                Catch Up
              </button>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body p-5">
            <h3 class="card-title text-base">
              <.icon name="hero-arrow-uturn-left" class="size-5 text-warning" />
              Reingest from MTGA Events
            </h3>
            <p class="text-sm text-base-content/60">
              Clears all domain events and re-translates from the raw MTGA event store.
              Then rebuilds all projections. Use after changing the event translator.
            </p>
            <div class="card-actions justify-end mt-2">
              <button
                phx-click="reingest"
                disabled={busy?(assigns)}
                data-confirm="This will clear all domain events and re-translate from raw MTGA events. Continue?"
                class="btn btn-soft btn-warning btn-sm"
              >
                Reingest
              </button>
            </div>
          </div>
        </div>
      </section>

      <%!-- Unrecognized event types (moved from the old dashboard) --%>
      <section :if={map_size(@unrecognized) > 0} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <p class="font-semibold">Unrecognized event types</p>
          <p class="text-sm mb-2">
            These MTGA event types have no handler or ignore clause in
            IdentifyDomainEvents (ADR-020).
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
                <tr :for={{type, count} <- sort_events_by_count(@unrecognized)}>
                  <td><code>{type}</code></td>
                  <td class="text-right tabular-nums">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <%!-- Deferred event types with payloads --%>
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
                <tr :for={{type, count} <- sort_events_by_count(@deferred_with_payloads)}>
                  <td><code>{type}</code></td>
                  <td class="text-right tabular-nums">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <%!-- Processing errors --%>
      <section :if={@errors != []} class="alert alert-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        <div>
          <p class="font-semibold">Processing errors ({@error_count})</p>
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

      <%!-- Full log-events-by-type breakdown --%>
      <section :if={map_size(@raw_events_by_type) > 0}>
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
              <tr :for={{type, count} <- sort_events_by_count(@raw_events_by_type)}>
                <td><code>{type}</code></td>
                <td class="text-right tabular-nums">{count}</td>
              </tr>
            </tbody>
          </table>
        </div>
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
                <th>Status</th>
                <th class="text-right">Rows</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={proj <- @projectors}>
                <td class="text-sm"><.projector_name name={proj.name} /></td>
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
                <td>
                  <span :if={proj.caught_up} class="badge badge-sm badge-soft badge-success gap-1">
                    <.icon name="hero-check-circle-mini" class="size-3" /> Caught up
                  </span>
                  <span :if={!proj.caught_up} class="badge badge-sm badge-soft badge-warning gap-1">
                    <.icon name="hero-exclamation-triangle-mini" class="size-3" /> Behind
                  </span>
                </td>
                <td class="text-right font-mono text-sm">
                  {format_number(proj.row_count)}
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
