defmodule Scry2Web.CollectionDiagnosticsLive do
  @moduledoc """
  Observability surface for the memory-snapshot reconciliation engine
  (the card-acquisition ledger built on `Scry2.Collection.SnapshotDiff`).

  Answers: is the engine running, what is it learning, and how do its
  results look over time? KPIs, an activity bar chart (acquired up,
  removed down), a cumulative collection-growth line, and a refresh
  timeline coloured by reader confidence.

  All non-trivial logic lives in `Scry2Web.CollectionDiagnosticsHelpers`
  (ADR-013) so the LiveView stays thin wiring.
  """

  use Scry2Web, :live_view

  alias Scry2.Collection
  alias Scry2.Topics
  alias Scry2Web.CollectionDiagnosticsHelpers, as: H

  @recent_diffs_limit 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.collection_snapshots())
      Topics.subscribe(Topics.collection_diffs())
    end

    {:ok, assign(socket, page_title: "Collection diagnostics")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:snapshot_saved, _}, socket), do: {:noreply, load_data(socket)}
  def handle_info({:diff_saved, _}, socket), do: {:noreply, load_data(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    snapshots = Collection.list_snapshots(limit: 500)
    diffs = Collection.list_diffs(limit: 500)
    snapshot_count = Collection.count_snapshots()
    diff_count = Collection.count_diffs()
    empty_diff_count = Collection.count_empty_diffs()
    reader_breakdown = Collection.reader_path_breakdown()
    top_diffs = Collection.top_diffs_by_acquired(5)
    latest_snapshot = Collection.current()
    signal_ratio = H.noise_signal_ratio(diff_count, empty_diff_count)
    walker_share = H.walker_share(reader_breakdown)

    assign(socket,
      snapshot_count: snapshot_count,
      diff_count: diff_count,
      empty_diff_count: empty_diff_count,
      reader_breakdown: reader_breakdown,
      walker_share: walker_share,
      signal_ratio: signal_ratio,
      latest_snapshot: latest_snapshot,
      recent_diffs: Enum.take(diffs, @recent_diffs_limit),
      top_diffs: top_diffs,
      activity_series: Jason.encode!(H.activity_series(diffs)),
      growth_series: Jason.encode!(H.growth_series(snapshots)),
      refresh_dots_series: Jason.encode!(H.refresh_dots_series(snapshots))
    )
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
      <div class="flex items-baseline justify-between mb-6">
        <h1 class="text-2xl font-semibold font-beleren">Collection diagnostics</h1>
        <.link navigate={~p"/collection"} class="text-sm link link-hover">
          ← Back to Collection
        </.link>
      </div>

      <%= if @snapshot_count == 0 do %>
        <.empty />
      <% else %>
        <div class="space-y-8">
          <.kpi_grid
            snapshot_count={@snapshot_count}
            diff_count={@diff_count}
            empty_diff_count={@empty_diff_count}
            signal_ratio={@signal_ratio}
            walker_share={@walker_share}
            latest_snapshot={@latest_snapshot}
          />

          <.chart_card
            title="Acquisition activity"
            subtitle="Per-snapshot card delta. Bars above = cards gained, bars below = cards lost."
          >
            <div
              id="chart-reconciliation-activity"
              phx-hook="Chart"
              data-chart-type="reconciliation_activity"
              data-series={@activity_series}
              class="w-full rounded-lg bg-base-200"
              style="height: 18rem"
            />
          </.chart_card>

          <.chart_card
            title="Collection growth"
            subtitle="Total copies in your collection over time."
          >
            <div
              id="chart-reconciliation-growth"
              phx-hook="Chart"
              data-chart-type="reconciliation_growth"
              data-series={@growth_series}
              class="w-full rounded-lg bg-base-200"
              style="height: 14rem"
            />
          </.chart_card>

          <.chart_card
            title="Refresh attempts"
            subtitle="Each dot is one snapshot. Green = direct walker read, amber = fallback scan."
          >
            <div
              id="chart-reconciliation-dots"
              phx-hook="Chart"
              data-chart-type="reconciliation_refresh_dots"
              data-series={@refresh_dots_series}
              class="w-full rounded-lg bg-base-200"
              style="height: 7rem"
            />
          </.chart_card>

          <div class="grid lg:grid-cols-2 gap-6">
            <.recent_diffs_card diffs={@recent_diffs} />
            <.top_diffs_card diffs={@top_diffs} />
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp empty(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-2xl" data-role="diagnostics-empty">
      <div class="card-body space-y-3">
        <h2 class="card-title">No data yet</h2>
        <p class="text-sm opacity-80">
          The reconciliation engine has not captured any snapshots. Open
          <.link navigate={~p"/collection"} class="link link-primary">Collection</.link>
          and click <strong>Refresh now</strong>
          with MTGA running to record the first snapshot.
        </p>
      </div>
    </div>
    """
  end

  attr :snapshot_count, :integer, required: true
  attr :diff_count, :integer, required: true
  attr :empty_diff_count, :integer, required: true
  attr :signal_ratio, :any, required: true
  attr :walker_share, :any, required: true
  attr :latest_snapshot, :any, required: true

  defp kpi_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4" data-role="diagnostics-kpis">
      <.kpi label="Snapshots" value={H.format_count(@snapshot_count)} key="snapshot-count" />
      <.kpi label="Diffs" value={H.format_count(@diff_count)} key="diff-count" />
      <.kpi
        label="Empty diffs"
        value={H.format_count(@empty_diff_count)}
        hint="Refreshes that recorded no change. High share = polling more often than the collection changes."
        key="empty-diffs"
        tone={:muted}
      />
      <.kpi
        label="Informative share"
        value={H.format_percent(@signal_ratio)}
        hint="Share of diffs that recorded an actual card change. 100% = every refresh saw new data."
        key="signal-ratio"
      />
      <.kpi
        label="Walker share"
        value={H.format_percent(@walker_share)}
        hint="Share of snapshots taken via the high-confidence walker path vs the structural fallback scan."
        key="walker-share"
        tone={:muted}
      />
      <.kpi
        label="Last refresh"
        value={relative_time(@latest_snapshot && @latest_snapshot.snapshot_ts)}
        hint={
          @latest_snapshot &&
            Calendar.strftime(@latest_snapshot.snapshot_ts, "%Y-%m-%d %H:%M UTC")
        }
        key="last-refresh"
        tone={:muted}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :key, :string, required: true
  attr :hint, :any, default: nil
  attr :tone, :atom, default: :numeric, values: [:numeric, :muted]

  defp kpi(assigns) do
    ~H"""
    <div
      class="bg-base-200 border border-base-300 rounded-lg p-4 min-w-0"
      data-kpi={@key}
      title={@hint}
    >
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class={["mt-1 truncate", kpi_value_class(@tone)]}>{@value}</div>
    </div>
    """
  end

  defp kpi_value_class(:numeric), do: "text-2xl font-semibold tabular-nums"
  defp kpi_value_class(:muted), do: "text-base font-medium tabular-nums text-base-content/80"

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp chart_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body">
        <div class="flex items-baseline justify-between gap-3">
          <h2 class="card-title">{@title}</h2>
          <p :if={@subtitle} class="text-xs text-base-content/60">{@subtitle}</p>
        </div>
        <div class="mt-3">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :diffs, :list, required: true

  defp recent_diffs_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300" data-role="recent-diffs">
      <div class="card-body">
        <h2 class="card-title">Recent diffs</h2>
        <p class="text-xs text-base-content/60">
          Most recent {length(@diffs)} reconciliation events, newest first.
        </p>
        <div class="mt-3 overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th class="text-right">Acquired</th>
                <th class="text-right">Removed</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={diff <- @diffs} class="hover">
                <td
                  class="text-sm text-base-content/80"
                  title={Calendar.strftime(diff.inserted_at, "%Y-%m-%d %H:%M UTC")}
                >
                  {relative_time(diff.inserted_at)}
                </td>
                <td class={[
                  "text-right tabular-nums",
                  diff.total_acquired > 0 && "text-emerald-400"
                ]}>
                  +{diff.total_acquired}
                </td>
                <td class={[
                  "text-right tabular-nums",
                  diff.total_removed > 0 && "text-orange-400"
                ]}>
                  −{diff.total_removed}
                </td>
              </tr>
              <tr :if={@diffs == []}>
                <td colspan="3" class="text-center text-sm text-base-content/60 py-4">
                  No diffs yet.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :diffs, :list, required: true

  defp top_diffs_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300" data-role="top-diffs">
      <div class="card-body">
        <h2 class="card-title">Biggest acquisitions</h2>
        <p class="text-xs text-base-content/60">
          Top diffs by total cards acquired. Spikes here usually correspond to
          set releases, vault opens, or large draft pools.
        </p>
        <div class="mt-3 overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th class="text-right">Acquired</th>
                <th class="text-right">Removed</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={diff <- @diffs} class="hover">
                <td
                  class="text-sm text-base-content/80"
                  title={Calendar.strftime(diff.inserted_at, "%Y-%m-%d %H:%M UTC")}
                >
                  {relative_time(diff.inserted_at)}
                </td>
                <td class="text-right tabular-nums text-emerald-400">+{diff.total_acquired}</td>
                <td class="text-right tabular-nums text-base-content/60">−{diff.total_removed}</td>
              </tr>
              <tr :if={@diffs == []}>
                <td colspan="3" class="text-center text-sm text-base-content/60 py-4">
                  No diffs yet.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
