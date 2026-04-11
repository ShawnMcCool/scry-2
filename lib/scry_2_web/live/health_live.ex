defmodule Scry2Web.HealthLive do
  @moduledoc """
  Landing page LiveView — the scry_2 health screen.

  Replaces `DashboardLive` at `/`. Runs a full `Scry2.Health.run_all/0`
  snapshot on every mount/patch and subscribes to PubSub for live
  updates as the watcher reports status changes, cards refresh, and
  domain events flow.

  All non-trivial rendering logic lives in `Scry2Web.HealthHelpers`
  (ADR-013) so the LiveView stays thin wiring.
  """
  use Scry2Web, :live_view

  alias Scry2.Health
  alias Scry2.SetupFlow
  alias Scry2.Topics
  alias Scry2Web.HealthHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.cards_updates())
      Topics.subscribe(Topics.domain_events())
      Topics.subscribe(Topics.operations())
    end

    {:ok,
     socket
     |> assign(:page_title, "Health")
     |> assign(:report, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :report, Health.run_all())}
  end

  @impl true
  def handle_info(_msg, socket) do
    # Any PubSub update triggers a full re-read of the health report.
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Health</h1>
        <button phx-click="reset_setup" class="btn btn-ghost btn-xs">
          Run setup tour again
        </button>
      </div>

      <.overall_banner :if={@report} report={@report} />

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
    <div class={["alert", HealthHelpers.overall_class(@report.overall)]}>
      <.icon name={HealthHelpers.status_icon(@report.overall)} class="size-5" />
      <div>
        <p class="font-semibold">{HealthHelpers.overall_message(@report.overall)}</p>
        <p class="text-xs text-base-content/70">
          Last checked at {Calendar.strftime(@report.generated_at, "%H:%M:%S UTC")}
        </p>
      </div>
    </div>
    """
  end

  attr :category, :atom, required: true
  attr :checks, :list, required: true

  defp category_section(assigns) do
    ~H"""
    <section class="space-y-2">
      <h2 class="text-lg font-semibold">{HealthHelpers.category_label(@category)}</h2>
      <div class="grid grid-cols-1 gap-2">
        <.check_row :for={check <- @checks} check={check} />
      </div>
    </section>
    """
  end

  attr :check, Scry2.Health.Check, required: true

  defp check_row(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4">
        <div class="flex items-start gap-3">
          <.icon
            name={HealthHelpers.status_icon(@check.status)}
            class={["size-5 mt-0.5", icon_color(@check.status)]}
          />
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <p class="font-medium">{@check.name}</p>
              <span class={["badge badge-xs", HealthHelpers.status_badge_class(@check.status)]}>
                {HealthHelpers.status_label(@check.status)}
              </span>
            </div>
            <p :if={@check.summary} class="text-sm text-base-content/70 break-all">
              {@check.summary}
            </p>
            <p :if={@check.detail} class="text-xs text-base-content/60 mt-1">
              {@check.detail}
            </p>
          </div>
          <.fix_button :if={fixable?(@check)} check={@check} />
        </div>
      </div>
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
       when fix in [:reload_watcher, :enqueue_lands17, :enqueue_scryfall], do: true

  defp fixable?(_), do: false

  defp icon_color(:ok), do: "text-success"
  defp icon_color(:warning), do: "text-warning"
  defp icon_color(:error), do: "text-error"
  defp icon_color(:pending), do: "text-info"
end
