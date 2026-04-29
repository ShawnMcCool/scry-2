defmodule Scry2Web.HealthLive do
  @moduledoc """
  System tab of the Settings group — the scry_2 health screen plus
  the self-update status card.

  Mounted at `/` as the permanent landing page and first tab of the
  Settings group (System | Operations | Settings). Runs a full
  `Scry2.Health.run_all/0` snapshot on every mount/patch and subscribes
  to PubSub for live updates as the watcher reports status changes,
  cards refresh, and domain events flow. Also owns the Updates card —
  subscribes to `Scry2.SelfUpdate` status/progress topics and renders
  version/release info at the top of the page.

  All non-trivial rendering logic lives in `Scry2Web.HealthHelpers`
  (ADR-013) so the LiveView stays thin wiring.
  """
  use Scry2Web, :live_view

  alias Scry2.Health
  alias Scry2.SelfUpdate
  alias Scry2.SetupFlow
  alias Scry2.Topics
  alias Scry2Web.HealthHelpers
  alias Scry2Web.SettingsLive.ApplyModal
  alias Scry2Web.SettingsLive.UpdatesCard
  alias Scry2Web.SettingsLive.UpdatesHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.cards_updates())
      Topics.subscribe(Topics.domain_events())
      Topics.subscribe(Topics.operations())
      SelfUpdate.subscribe_status()
      SelfUpdate.subscribe_progress()
      maybe_auto_check_updates()
    end

    current_version = SelfUpdate.current_version()
    current_status = SelfUpdate.current_status()
    checking? = connected?(socket) and not SelfUpdate.cache_fresh?()

    updates_summary =
      UpdatesHelpers.summarize(
        SelfUpdate.last_known_release(),
        current_version,
        current_status.phase,
        nil,
        checking?
      )

    apply_phase = apply_phase_from_status(current_status.phase)

    {:ok,
     socket
     |> assign(:page_title, "System")
     |> assign(:report, nil)
     |> assign(:updates_current_version, current_version)
     |> assign(:updates_last_check_at, SelfUpdate.last_check_at())
     |> assign(:updates_summary, updates_summary)
     |> assign(:apply_phase, apply_phase)
     |> assign(:apply_error, current_status.error)
     |> assign(:apply_failed_at, nil)
     |> assign(:apply_progress, nil)}
  end

  # The Updater reports :idle when nothing is happening. We treat :idle
  # as nil for modal-visibility purposes — the modal only renders for
  # in-flight or just-terminated applies.
  defp apply_phase_from_status(:idle), do: nil
  defp apply_phase_from_status(phase), do: phase

  # Oban's unique constraint on the CheckerJob worker+args deduplicates
  # repeated manual triggers within 55 minutes, so firing on every mount
  # is safe — at most one real HTTP call per user per window.
  defp maybe_auto_check_updates do
    if Application.get_env(:scry_2, :auto_check_updates_on_mount, true) and
         not SelfUpdate.cache_fresh?() do
      _ = SelfUpdate.check_now()
    end

    :ok
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :report, Health.run_all())}
  end

  @impl true
  def handle_info(:check_started, socket) do
    {:noreply,
     assign(
       socket,
       :updates_summary,
       Map.put(socket.assigns.updates_summary, :checking, true)
     )}
  end

  def handle_info({:check_complete, result}, socket) do
    last_error =
      case result do
        {:ok, _} ->
          nil

        {:error, reason} ->
          UpdatesHelpers.format_error(reason, DateTime.utc_now())
      end

    {:noreply,
     socket
     |> assign(
       :updates_summary,
       UpdatesHelpers.summarize(
         SelfUpdate.last_known_release(),
         socket.assigns.updates_current_version,
         socket.assigns.updates_summary[:applying],
         last_error,
         false
       )
     )
     |> assign(:updates_last_check_at, SelfUpdate.last_check_at())}
  end

  def handle_info({:phase, :failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(
       :updates_summary,
       Map.put(socket.assigns.updates_summary, :applying, :failed)
     )
     |> assign(:apply_phase, :failed)
     |> assign(:apply_error, reason)
     |> assign(:apply_failed_at, socket.assigns.apply_phase)}
  end

  def handle_info({:phase, phase}, socket) do
    # Reset apply_progress on every phase transition — the bar is only
    # meaningful during :downloading, and leaving stale percent around
    # would paint it on the next download's spinner row otherwise.
    {:noreply,
     socket
     |> assign(
       :updates_summary,
       Map.put(socket.assigns.updates_summary, :applying, phase)
     )
     |> assign(:apply_phase, phase)
     |> assign(:apply_progress, nil)}
  end

  def handle_info({:download_progress, pct}, socket) do
    {:noreply, assign(socket, :apply_progress, pct)}
  end

  def handle_info({:apply_cancelled}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, nil)
     |> assign(:apply_error, nil)
     |> assign(:apply_failed_at, nil)
     |> assign(:apply_progress, nil)
     |> assign(
       :updates_summary,
       Map.put(socket.assigns.updates_summary, :applying, nil)
     )}
  end

  def handle_info(_msg, socket) do
    # Any other PubSub update triggers a full re-read of the health report.
    # The report is cheap (no heavy queries) and keeping a single data
    # source is simpler than tracking deltas per message type.
    {:noreply, assign(socket, :report, Health.run_all())}
  end

  @impl true
  def handle_event("auto_fix", %{"fix" => fix_tag}, socket) do
    fix = String.to_existing_atom(fix_tag)
    _ = Health.auto_fix(fix)
    {:noreply, assign(socket, :report, Health.run_all())}
  end

  def handle_event("reset_setup", _params, socket) do
    :ok = SetupFlow.reset!()
    {:noreply, push_navigate(socket, to: ~p"/setup")}
  end

  def handle_event("updates_check_now", _params, socket) do
    _ = SelfUpdate.check_now()
    {:noreply, socket}
  end

  def handle_event("updates_apply", _params, socket) do
    _ = SelfUpdate.apply_pending()

    # Open the modal immediately in :preparing state — the Updater broadcasts
    # this phase as it starts, but the PubSub round-trip means the UI can
    # briefly look frozen after the click otherwise.
    {:noreply,
     socket
     |> assign(:apply_phase, :preparing)
     |> assign(:apply_error, nil)
     |> assign(:apply_failed_at, nil)
     |> assign(:apply_progress, nil)}
  end

  def handle_event("cancel_update", _params, socket) do
    _ = SelfUpdate.cancel_apply()
    {:noreply, socket}
  end

  def handle_event("dismiss_apply_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, nil)
     |> assign(:apply_error, nil)
     |> assign(:apply_failed_at, nil)
     |> assign(:apply_progress, nil)}
  end

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
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold font-beleren">Settings</h1>
        <button phx-click="reset_setup" class="btn btn-ghost btn-xs">
          Run setup tour again
        </button>
      </div>

      <.settings_tabs current_path={@player_scope_uri} />

      <UpdatesCard.updates_card
        summary={@updates_summary}
        current_version={@updates_current_version}
        last_check_at={@updates_last_check_at}
      />

      <.overall_banner :if={@report} report={@report} />

      <ApplyModal.apply_modal
        apply_phase={@apply_phase}
        apply_error={@apply_error}
        apply_failed_at={@apply_failed_at}
        apply_progress={@apply_progress}
        release_tag={@updates_summary[:version] && "v#{@updates_summary.version}"}
      />

      <.category_section
        :for={{category, checks} <- categories(@report)}
        category={category}
        checks={checks}
      />
    </Layouts.app>
    """
  end

  defp categories(nil), do: []
  defp categories(report), do: HealthHelpers.ordered_categories(report)

  attr :report, Scry2.Health.Report, required: true

  defp overall_banner(assigns) do
    ~H"""
    <div class={["alert alert-sm py-2", HealthHelpers.overall_class(@report.overall)]}>
      <.icon name={HealthHelpers.status_icon(@report.overall)} class="size-4" />
      <span class="font-semibold text-sm">{HealthHelpers.overall_message(@report.overall)}</span>
      <span class="text-xs text-base-content/60">
        Last checked at {Calendar.strftime(@report.generated_at, "%H:%M:%S UTC")}
      </span>
    </div>
    """
  end

  attr :category, :atom, required: true
  attr :checks, :list, required: true

  defp category_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1.5">
        {HealthHelpers.category_label(@category)}
      </h2>
      <div class="divide-y divide-base-300 rounded-md bg-base-200">
        <.check_row :for={check <- @checks} check={check} />
      </div>
    </section>
    """
  end

  attr :check, Scry2.Health.Check, required: true

  defp check_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-3 py-2">
      <.icon
        name={HealthHelpers.status_icon(@check.status)}
        class={["size-4 shrink-0", icon_color(@check.status)]}
      />
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <p class="font-medium text-sm">{@check.name}</p>
          <span
            :if={@check.status != :ok}
            class={["badge badge-xs", HealthHelpers.status_badge_class(@check.status)]}
          >
            {HealthHelpers.status_label(@check.status)}
          </span>
          <span :if={@check.summary} class="text-xs text-base-content/60 break-all">
            {@check.summary}
          </span>
        </div>
        <p :if={@check.detail} class="text-xs text-base-content/50 mt-0.5">
          {@check.detail}
        </p>
      </div>
      <.fix_button :if={fixable?(@check)} check={@check} />
    </div>
    """
  end

  attr :check, Scry2.Health.Check, required: true

  defp fix_button(assigns) do
    ~H"""
    <button
      phx-click="auto_fix"
      phx-value-fix={to_string(@check.fix)}
      class="btn btn-xs btn-primary"
    >
      Retry
    </button>
    """
  end

  defp fixable?(%Scry2.Health.Check{fix: fix})
       when fix in [:reload_watcher, :enqueue_synthesis, :enqueue_scryfall], do: true

  defp fixable?(_), do: false

  defp icon_color(:ok), do: "text-success"
  defp icon_color(:warning), do: "text-warning"
  defp icon_color(:error), do: "text-error"
  defp icon_color(:pending), do: "text-info"
end
