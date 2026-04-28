defmodule Scry2Web.OperationsLive do
  use Scry2Web, :live_view

  alias Scry2.{Events, MtgaLogIngestion, Operations, Service, Topics}
  alias Scry2.Diagnostics.CrashDump
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.ProjectorRegistry
  alias Scry2.MtgaLogIngestion.GitHubIssueReport
  alias Scry2Web.SettingsLive.ServiceCard

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
     |> assign(:reload_timer, nil)
     |> assign(:report_modal, nil)
     |> assign_service()
     |> assign(:service_error, nil)}
  end

  defp assign_service(socket) do
    socket
    |> assign(:service_name, Service.name())
    |> assign(:service_state, Service.state())
    |> assign(:service_capabilities, Service.capabilities())
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_status(socket)}
  end

  defp load_status(socket) do
    status = Operations.status()
    domain_event_types = Events.count_by_type()
    total_domain = domain_event_types |> Map.values() |> Enum.sum()

    # Raw-event breakdowns — used by the unrecognized/deferred alert sections.
    raw_events_by_type = MtgaLogIngestion.count_by_type()
    known_types = IdentifyDomainEvents.known_event_types()
    deferred_types = IdentifyDomainEvents.deferred_event_types()

    unrecognized =
      Map.reject(raw_events_by_type, fn {type, _count} -> MapSet.member?(known_types, type) end)

    deferred_with_payloads = MtgaLogIngestion.deferred_types_with_payloads(deferred_types)

    errors =
      if status.error_count > 0 do
        MtgaLogIngestion.list_errors()
        |> Enum.map(fn record ->
          %{
            id: record.id,
            event_type: record.event_type,
            processing_error: record.processing_error,
            occurred_at: record.mtga_timestamp,
            friendly: MtgaLogIngestion.user_friendly_error(record.processing_error)
          }
        end)
      else
        []
      end

    # Restore last operation state so the section survives page reload /
    # WebSocket reconnect. Only applied when no operation is already tracked
    # in assigns (i.e. fresh mount) — live PubSub updates take precedence.
    socket =
      if socket.assigns.operation == nil do
        case Operations.last_operation() do
          %{type: type, running: true} ->
            socket
            |> assign(:operation, type)
            |> assign(:operation_running, true)

          _completed_or_nil ->
            socket
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
    |> assign(:unrecognized, unrecognized)
    |> assign(:deferred_with_payloads, deferred_with_payloads)
    |> assign(:errors, errors)
    |> assign(:last_crash, CrashDump.latest_summary())
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

  def handle_event("reingest", _params, socket) do
    Operations.start_reingest!()
    {:noreply, socket}
  end

  def handle_event("export_errors", _params, socket) do
    export = MtgaLogIngestion.export_errors()

    filename =
      "scry2-error-report-#{Calendar.strftime(export.exported_at, "%Y-%m-%d")}.json"

    content = Jason.encode!(export, pretty: true)

    {:noreply, push_event(socket, "operations:download", %{filename: filename, content: content})}
  end

  def handle_event("dismiss_error", %{"id" => id_string}, socket) do
    id_string |> String.to_integer() |> MtgaLogIngestion.dismiss_error!()
    {:noreply, load_status(socket)}
  end

  def handle_event("dismiss_all_errors", _params, socket) do
    MtgaLogIngestion.dismiss_all_errors!()
    {:noreply, load_status(socket)}
  end

  def handle_event("open_report_modal", _params, socket) do
    report = GitHubIssueReport.build(MtgaLogIngestion.export_errors())
    {:noreply, assign(socket, :report_modal, report)}
  end

  def handle_event("close_report_modal", _params, socket) do
    {:noreply, assign(socket, :report_modal, nil)}
  end

  def handle_event("dismiss_operation", _params, socket) do
    {:noreply,
     socket
     |> assign(:operation, nil)
     |> assign(:operation_running, false)
     |> assign(:progress, nil)
     |> assign(:steps, [])
     |> assign(:projector_progress, %{})
     |> assign(:pending_rebuilds, nil)}
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

  def handle_event("service_restart", _params, socket) do
    {:noreply, run_service_action(socket, &Service.restart/0, "Restarting backend…")}
  end

  def handle_event("service_stop", _params, socket) do
    {:noreply, run_service_action(socket, &Service.stop/0, "Stopping backend…")}
  end

  defp run_service_action(socket, action, info_message) do
    case action.() do
      :ok ->
        socket
        |> assign(:service_error, nil)
        |> put_flash(:info, info_message)

      :not_supported ->
        assign(socket, :service_error, "This action is not supported by the current supervisor.")

      {:error, reason} ->
        assign(socket, :service_error, "Service action failed: #{inspect(reason)}")
    end
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
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <h1 class="text-2xl font-semibold font-beleren">Settings</h1>
      <.settings_tabs current_path={@player_scope_uri} />

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
        <div class="card-body p-5 relative">
          <button
            :if={!@operation_running}
            type="button"
            phx-click="dismiss_operation"
            aria-label="Dismiss"
            class="btn btn-ghost btn-xs btn-circle absolute top-3 right-3"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>

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

      <%!-- Last BEAM crash (only when a previous run died hard) --%>
      <section :if={@last_crash} class="card bg-base-200 border border-warning/40">
        <div class="card-body p-5">
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
            <h2 class="card-title text-base">Last BEAM crash</h2>
          </div>
          <div class="text-sm space-y-1">
            <div :if={@last_crash.crashed_at_raw}>
              <span class="text-base-content/60">When:</span>
              <span class="font-mono">{@last_crash.crashed_at_raw}</span>
            </div>
            <div :if={@last_crash.slogan} class="break-all">
              <span class="text-base-content/60">Slogan:</span>
              <span class="font-mono text-error">{@last_crash.slogan}</span>
            </div>
            <div :if={@last_crash.system_version} class="text-xs text-base-content/40">
              {@last_crash.system_version}
            </div>
            <div :if={@last_crash.archived_path} class="text-xs text-base-content/40 mt-2">
              Full dump preserved at <span class="font-mono">{@last_crash.archived_path}</span>
            </div>
          </div>
        </div>
      </section>

      <%!-- Service controls --%>
      <ServiceCard.service_card
        name={@service_name}
        state={@service_state}
        capabilities={@service_capabilities}
        error={@service_error}
      />

      <%!-- Action cards --%>
      <section class="grid grid-cols-1 gap-4 md:grid-cols-2">
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
      <section :if={map_size(@unrecognized) > 0} class="alert alert-soft alert-warning">
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
      <section :if={map_size(@deferred_with_payloads) > 0} class="alert alert-soft alert-info">
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
      <section
        :if={@errors != []}
        id="operations-error-section"
        phx-hook="OperationsDownload"
        class="card bg-base-200 border border-error/30"
      >
        <div class="card-body p-5 gap-4">
          <div class="flex items-start justify-between gap-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-exclamation-circle" class="size-5 text-error shrink-0" />
              <div>
                <p class="font-semibold">
                  {if @error_count == 1,
                    do: "1 event could not be processed",
                    else: "#{format_number(@error_count)} events could not be processed"}
                </p>
                <p class="text-sm text-base-content/60">
                  These errors don't affect your match history. Dismiss them or export the details below.
                </p>
              </div>
            </div>
            <div class="flex gap-2 shrink-0">
              <button
                phx-click="open_report_modal"
                class="btn btn-xs btn-soft btn-primary"
                title="Review and send these errors as a GitHub issue"
              >
                <.icon name="hero-megaphone" class="size-3" /> Report to developer
              </button>
              <button
                phx-click="export_errors"
                class="btn btn-xs btn-soft"
                title="Download a JSON report to send to the developer"
              >
                <.icon name="hero-arrow-down-tray" class="size-3" /> Export JSON
              </button>
              <button phx-click="dismiss_all_errors" class="btn btn-xs btn-ghost">
                Dismiss all
              </button>
            </div>
          </div>

          <ul class="space-y-3">
            <li :for={error <- @errors} class="bg-base-100 rounded-lg p-4">
              <div class="flex items-start justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <p class="font-semibold text-sm">{error.friendly.title}</p>
                  <p class="text-sm text-base-content/70 mt-1">{error.friendly.explanation}</p>
                  <p class="text-sm text-base-content/50 mt-1 italic">{error.friendly.action}</p>
                  <div class="flex items-center gap-2 mt-2 flex-wrap">
                    <code class="badge badge-xs badge-ghost">{error.event_type}</code>
                    <span :if={error.occurred_at} class="text-xs text-base-content/40">
                      {Calendar.strftime(error.occurred_at, "%Y-%m-%d %H:%M")}
                    </span>
                  </div>
                  <details class="mt-2">
                    <summary class="text-xs text-base-content/40 cursor-pointer select-none hover:text-base-content/60">
                      Technical details
                    </summary>
                    <p class="text-xs font-mono text-base-content/50 mt-1 break-all whitespace-pre-wrap">
                      {error.processing_error}
                    </p>
                  </details>
                </div>
                <button
                  phx-click="dismiss_error"
                  phx-value-id={error.id}
                  class="btn btn-xs btn-ghost shrink-0"
                  title="Dismiss"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
            </li>
          </ul>
        </div>
      </section>

      <%!-- Projections table --%>
      <section>
        <h2 class="text-lg font-semibold mb-3 font-beleren">Projections</h2>
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
                    <.icon name="hero-check-circle-mini" class="size-3" /> Caught&nbsp;up
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

      <%!-- Report-to-developer modal --%>
      <%= if @report_modal do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div
            class="w-full max-w-2xl max-h-[85vh] overflow-y-auto rounded-2xl bg-base-100 shadow-2xl border border-base-300"
            phx-click-away="close_report_modal"
            phx-window-keydown="close_report_modal"
            phx-key="Escape"
          >
            <div class="p-6 space-y-4">
              <div class="space-y-1">
                <h2 class="text-xl font-semibold font-beleren">
                  Report these errors to the developer
                </h2>
                <p class="text-sm text-base-content/70">
                  This opens a pre-filled GitHub issue. Review the data below — when you confirm, your browser will navigate to GitHub. Nothing is sent without your action.
                </p>
              </div>

              <div class="space-y-2">
                <p class="text-xs uppercase tracking-wide text-base-content/50">Issue title</p>
                <div class="rounded-lg bg-base-200/60 px-3 py-2 font-mono text-sm break-words">
                  {@report_modal.title}
                </div>
              </div>

              <div class="space-y-2">
                <p class="text-xs uppercase tracking-wide text-base-content/50">
                  Issue body (preview)
                </p>
                <pre class="rounded-lg bg-base-200/60 p-3 text-xs leading-relaxed whitespace-pre-wrap break-words max-h-72 overflow-y-auto">{@report_modal.body}</pre>
              </div>

              <div class="space-y-1">
                <p class="text-xs uppercase tracking-wide text-base-content/50">Signatures</p>
                <ul class="text-xs space-y-1">
                  <li :for={sig <- @report_modal.signatures} class="font-mono text-base-content/70">
                    <span class="badge badge-xs badge-ghost mr-2">×{sig.count}</span>
                    {elem(sig.signature, 0)}
                    <span class="text-base-content/40">— {elem(sig.signature, 1)}</span>
                  </li>
                </ul>
              </div>

              <div class="flex items-center justify-end gap-4 pt-2">
                <button
                  phx-click="close_report_modal"
                  type="button"
                  class="link link-hover text-sm text-base-content/60"
                >
                  no, I don't agree
                </button>
                <a
                  href={@report_modal.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  phx-click="close_report_modal"
                  class="btn btn-primary btn-sm gap-2"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Send to GitHub
                </a>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
