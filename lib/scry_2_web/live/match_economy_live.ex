defmodule Scry2Web.MatchEconomyLive do
  @moduledoc """
  Per-match economy timeline. Shows daily-rollup chart (added in
  follow-up) plus a paginated, date-filterable table of every match's
  memory deltas, log deltas, diffs, and reconciliation state.
  """

  use Scry2Web, :live_view

  alias Scry2.MatchEconomy

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Scry2.Topics.subscribe(Scry2.Topics.match_economy_updates())

    {:ok,
     socket
     |> assign(:page_title, "Match economy")
     |> assign(:since, nil)
     |> assign(:until, nil)
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> load_data()}
  end

  @impl true
  def handle_event("filter", %{"since" => since, "until" => until_str}, socket) do
    since_dt = parse_date(since)
    until_dt = parse_date(until_str, end_of_day: true)

    {:noreply,
     socket
     |> assign(:since, since_dt)
     |> assign(:until, until_dt)
     |> assign(:page, 1)
     |> load_data()}
  end

  def handle_event("page", %{"page" => page_str}, socket) do
    page = max(1, String.to_integer(page_str))

    {:noreply,
     socket
     |> assign(:page, page)
     |> load_data()}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(:since, nil)
     |> assign(:until, nil)
     |> assign(:page, 1)
     |> load_data()}
  end

  @impl true
  def handle_info({:match_economy_updated, _summary}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    filter = filter_opts(socket)
    total = MatchEconomy.count_summaries(filter)

    summaries =
      MatchEconomy.recent_summaries(
        filter ++
          [
            limit: socket.assigns.per_page,
            offset: (socket.assigns.page - 1) * socket.assigns.per_page
          ]
      )

    socket
    |> assign(:summaries, summaries)
    |> assign(:total, total)
    |> assign(
      :total_pages,
      max(1, div(total + socket.assigns.per_page - 1, socket.assigns.per_page))
    )
    |> assign(:timeline, MatchEconomy.timeline(filter))
  end

  defp filter_opts(socket) do
    []
    |> maybe_put(:since, socket.assigns.since)
    |> maybe_put(:until, socket.assigns.until)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Header clause to allow default arg with multiple clauses below.
  defp parse_date(str, opts \\ [])
  defp parse_date("", _opts), do: nil
  defp parse_date(nil, _opts), do: nil

  defp parse_date(str, opts) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} ->
        time = if opts[:end_of_day], do: ~T[23:59:59.999999], else: ~T[00:00:00]
        DateTime.new!(date, time, "Etc/UTC")

      {:error, _} ->
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <h1 class="text-xl font-semibold">Match economy</h1>

      <section data-test="chart-placeholder" class="card bg-base-200">
        <div class="card-body p-4">
          <p class="text-sm opacity-70">Daily-rollup chart goes here (follow-up).</p>
        </div>
      </section>

      <section class="card bg-base-200" data-test="filter-bar">
        <div class="card-body p-4">
          <form phx-change="filter" class="flex flex-wrap items-end gap-3">
            <label class="form-control">
              <span class="text-xs opacity-70">From</span>
              <input
                type="date"
                name="since"
                value={date_value(@since)}
                class="input input-sm input-bordered"
              />
            </label>

            <label class="form-control">
              <span class="text-xs opacity-70">Until</span>
              <input
                type="date"
                name="until"
                value={date_value(@until)}
                class="input input-sm input-bordered"
              />
            </label>

            <button
              :if={@since || @until}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="clear_filter"
            >
              Clear
            </button>
          </form>
        </div>
      </section>

      <section class="card bg-base-200" data-test="match-table">
        <div class="card-body p-4">
          <h2 class="card-title text-sm uppercase tracking-wide opacity-70">
            Matches ({@total})
          </h2>

          <div :if={@summaries == []} class="text-sm opacity-70">
            No match-economy data for this filter.
          </div>

          <div :if={@summaries != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Ended</th>
                  <th>Match</th>
                  <th>State</th>
                  <th>Memory gold</th>
                  <th>Log gold</th>
                  <th>Diff gold</th>
                  <th>Memory gems</th>
                  <th>Log gems</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={summary <- @summaries}>
                  <td>{format_dt(summary.ended_at)}</td>
                  <td class="font-mono text-xs">{summary.mtga_match_id}</td>
                  <td>
                    <span class={state_badge_class(summary.reconciliation_state)}>
                      {summary.reconciliation_state}
                    </span>
                  </td>
                  <td>{format_int(summary.memory_gold_delta)}</td>
                  <td>{format_int(summary.log_gold_delta)}</td>
                  <td>
                    <span
                      :if={summary.diff_gold not in [nil, 0]}
                      class="badge badge-soft badge-warning"
                    >
                      {format_int(summary.diff_gold)}
                    </span>
                  </td>
                  <td>{format_int(summary.memory_gems_delta)}</td>
                  <td>{format_int(summary.log_gems_delta)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@total_pages > 1} class="mt-4 flex justify-between items-center text-sm">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="page"
              phx-value-page={@page - 1}
              disabled={@page <= 1}
            >
              ← Prev
            </button>
            <span class="opacity-70">Page {@page} of {@total_pages}</span>
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="page"
              phx-value-page={@page + 1}
              disabled={@page >= @total_pages}
            >
              Next →
            </button>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp date_value(nil), do: ""
  defp date_value(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_int(nil), do: "—"
  defp format_int(0), do: "—"
  defp format_int(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp format_int(n) when is_integer(n), do: "#{n}"

  defp state_badge_class("complete"), do: "badge badge-soft badge-success"
  defp state_badge_class("log_only"), do: "badge badge-soft badge-info"
  defp state_badge_class("incomplete"), do: "badge badge-soft badge-warning"
  defp state_badge_class(_), do: "badge badge-ghost"
end
