defmodule Scry2Web.MtgaMemoryLive do
  @moduledoc """
  Operator-facing diagnostics for the memory-reader subsystem
  (`Scry2.MtgaMemory.Nif` + the `walker_*` NIFs).

  This page is the single window into what the walker is doing right
  now: which MTGA process it sees, what its last `walk_match_info` /
  `walk_match_board` call cost (reads_used, elapsed time), what the
  per-pid discovery cache holds, and ad-hoc class/field probes for
  reverse-engineering future builds.

  All non-trivial logic lives in `Scry2Web.MtgaMemoryHelpers` (ADR-013)
  so the LiveView stays thin wiring.

  Useful reading:
  - `decisions/architecture/2026-04-21-034-mono-memory-reading.md` — why the walker exists
  - `mtga-duress/experiments/spikes/spike19_read_budget_regression/FINDING.md` — read-budget background
  - `.claude/skills/mono-memory-reader/SKILL.md` — wire format and offset table
  """

  use Scry2Web, :live_view

  alias Scry2.MtgaMemory
  alias Scry2.MtgaMemory.Nif
  alias Scry2Web.MtgaMemoryHelpers, as: H
  alias Scry2Web.SettingsTabs

  @max_classes_results 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Memory diagnostics")
     |> assign(:process_info, nil)
     |> assign(:process_error, nil)
     |> assign(:walker_runs, [])
     |> assign(:cache_snapshot, [])
     |> assign(:class_search_needle, "")
     |> assign(:class_search_results, nil)
     |> assign(:class_fields_name, "")
     |> assign(:class_fields_results, nil)
     |> assign(:assemblies_results, nil)
     |> refresh_process()
     |> refresh_cache()}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :player_scope_uri, URI.parse(uri).path)}
  end

  @impl true
  def handle_event("refresh_process", _params, socket) do
    {:noreply, refresh_process(socket)}
  end

  def handle_event("run_walker", _params, socket) do
    {:noreply, run_walker(socket)}
  end

  def handle_event("clear_walker_runs", _params, socket) do
    {:noreply, assign(socket, :walker_runs, [])}
  end

  def handle_event("invalidate_pid", %{"pid" => pid}, socket) do
    pid_int = String.to_integer(pid)
    Nif.walker_debug_cache_invalidate(pid_int)
    {:noreply, socket |> refresh_cache() |> put_flash(:info, "Cache invalidated for pid #{pid}.")}
  end

  def handle_event("clear_cache", _params, socket) do
    Nif.walker_debug_cache_clear()
    {:noreply, socket |> refresh_cache() |> put_flash(:info, "Discovery cache cleared.")}
  end

  def handle_event("refresh_cache", _params, socket) do
    {:noreply, refresh_cache(socket)}
  end

  def handle_event("class_search", %{"needle" => needle}, socket) do
    {:noreply,
     socket
     |> assign(:class_search_needle, needle)
     |> run_class_search(needle)}
  end

  def handle_event("class_fields", %{"name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:class_fields_name, name)
     |> run_class_fields(name)}
  end

  def handle_event("list_assemblies", _params, socket) do
    {:noreply, run_list_assemblies(socket)}
  end

  # ── Process probe ──────────────────────────────────────────────────

  defp refresh_process(socket) do
    case find_mtga_process() do
      {:ok, info} ->
        socket
        |> assign(:process_info, info)
        |> assign(:process_error, nil)

      {:error, reason} ->
        socket
        |> assign(:process_info, nil)
        |> assign(:process_error, reason)
    end
  end

  defp find_mtga_process do
    memory = MtgaMemory.impl()

    case memory.find_process(fn %{name: name} -> name == "MTGA.exe" end) do
      {:ok, pid} ->
        # find_process only returns a pid; re-resolve to grab the
        # name and cmdline so the operator can see what we matched.
        case Nif.list_processes_nif() do
          {:ok, rows} ->
            row = Enum.find(rows, fn {p, _, _} -> p == pid end)

            case row do
              {p, name, cmdline} ->
                {:ok, %{pid: p, name: name, cmdline: cmdline}}

              nil ->
                {:ok, %{pid: pid, name: "MTGA.exe", cmdline: ""}}
            end

          _ ->
            {:ok, %{pid: pid, name: "MTGA.exe", cmdline: ""}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Walker trace ───────────────────────────────────────────────────

  defp run_walker(socket) do
    case socket.assigns.process_info do
      nil ->
        put_flash(socket, :error, "No MTGA process detected — refresh and try again.")

      %{pid: pid} ->
        run = perform_walker_run(pid)
        runs = [run | socket.assigns.walker_runs] |> Enum.take(10)

        socket
        |> assign(:walker_runs, runs)
        |> refresh_cache()
    end
  end

  defp perform_walker_run(pid) do
    {info_t0, info_result, info_stats} = time_walk(:info, pid)
    {board_t0, board_result, board_stats} = time_walk(:board, pid)

    %{
      ts: System.system_time(:millisecond),
      pid: pid,
      info: %{
        result: info_result,
        stats: info_stats,
        elapsed_ms: info_t0
      },
      board: %{
        result: board_result,
        stats: board_stats,
        elapsed_ms: board_t0
      }
    }
  end

  defp time_walk(:info, pid) do
    t0 = System.monotonic_time(:millisecond)
    {result, stats} = Nif.walker_debug_walk_match_info_with_stats(pid)
    {System.monotonic_time(:millisecond) - t0, result, stats}
  end

  defp time_walk(:board, pid) do
    t0 = System.monotonic_time(:millisecond)
    {result, stats} = Nif.walker_debug_walk_match_board_with_stats(pid)
    {System.monotonic_time(:millisecond) - t0, result, stats}
  end

  # ── Discovery cache ────────────────────────────────────────────────

  defp refresh_cache(socket) do
    rows = Nif.walker_debug_cache_snapshot()
    assign(socket, :cache_snapshot, H.normalise_cache_snapshot(rows))
  end

  # ── Class search / class fields / assemblies ───────────────────────

  defp run_class_search(socket, needle) do
    needle = String.trim(needle)

    cond do
      needle == "" ->
        assign(socket, :class_search_results, {:error, "Enter a class-name substring."})

      socket.assigns.process_info == nil ->
        assign(socket, :class_search_results, {:error, "No MTGA process detected."})

      true ->
        pid = socket.assigns.process_info.pid

        case Nif.walker_debug_classes_matching(pid, needle) do
          {:ok, rows} ->
            assign(socket, :class_search_results, {:ok, Enum.take(rows, @max_classes_results)})

          {:error, reason} ->
            assign(socket, :class_search_results, {:error, inspect(reason)})
        end
    end
  end

  defp run_class_fields(socket, name) do
    name = String.trim(name)

    cond do
      name == "" ->
        assign(socket, :class_fields_results, {:error, "Enter a class name."})

      socket.assigns.process_info == nil ->
        assign(socket, :class_fields_results, {:error, "No MTGA process detected."})

      true ->
        pid = socket.assigns.process_info.pid

        case Nif.walker_debug_class_fields(pid, name) do
          {:ok, rows} -> assign(socket, :class_fields_results, {:ok, rows})
          {:error, reason} -> assign(socket, :class_fields_results, {:error, inspect(reason)})
        end
    end
  end

  defp run_list_assemblies(socket) do
    case socket.assigns.process_info do
      nil ->
        assign(socket, :assemblies_results, {:error, "No MTGA process detected."})

      %{pid: pid} ->
        case Nif.walker_debug_list_assemblies(pid) do
          {:ok, rows} -> assign(socket, :assemblies_results, {:ok, rows})
          {:error, reason} -> assign(socket, :assemblies_results, {:error, inspect(reason)})
        end
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

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
      <h1 class="text-2xl font-semibold font-beleren">Memory diagnostics</h1>
      <SettingsTabs.settings_tabs current_path={@player_scope_uri} />

      <div class="space-y-6 max-w-5xl">
        <.process_card process_info={@process_info} process_error={@process_error} />

        <.walker_card runs={@walker_runs} process_info={@process_info} />

        <.cache_card snapshot={@cache_snapshot} />

        <.class_search_card
          needle={@class_search_needle}
          results={@class_search_results}
        />

        <.class_fields_card
          name={@class_fields_name}
          results={@class_fields_results}
        />

        <.assemblies_card results={@assemblies_results} />

        <p class="text-xs text-base-content/60">
          Reads-used over budget tells you how close each walk is to the
          ceiling. The structural fix for budget regressions is already in
          place — wall-clock budget (500&nbsp;ms) plus per-pid discovery
          cache. Cache state above shows what's been resolved; clear it to
          force re-discovery.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :process_info, :any, required: true
  attr :process_error, :any, required: true

  defp process_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title text-base">MTGA process</h2>
          <button
            type="button"
            phx-click="refresh_process"
            class="btn btn-ghost btn-xs"
          >
            Refresh
          </button>
        </div>

        <%= cond do %>
          <% @process_info -> %>
            <div class="flex items-center gap-2">
              <span class="badge badge-soft badge-success">Detected</span>
              <code class="text-sm">pid={@process_info.pid}</code>
              <code class="text-sm">{@process_info.name}</code>
            </div>
            <p class="text-xs text-base-content/60 mt-2 break-all">
              {H.truncate_cmdline(@process_info.cmdline, 200)}
            </p>
          <% @process_error -> %>
            <div class="flex items-center gap-2">
              <span class="badge badge-soft badge-error">Not found</span>
              <code class="text-xs">{inspect(@process_error)}</code>
            </div>
            <p class="text-xs text-base-content/60 mt-1">
              Start MTGA, then click Refresh.
            </p>
          <% true -> %>
            <span class="badge badge-soft">Idle</span>
        <% end %>
      </div>
    </section>
    """
  end

  attr :runs, :list, required: true
  attr :process_info, :any, required: true

  defp walker_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title text-base">Walker trace</h2>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="run_walker"
              disabled={is_nil(@process_info)}
              class="btn btn-primary btn-sm"
            >
              Run trace
            </button>
            <button
              :if={@runs != []}
              type="button"
              phx-click="clear_walker_runs"
              class="btn btn-ghost btn-sm"
            >
              Clear
            </button>
          </div>
        </div>

        <p class="text-xs text-base-content/60">
          Runs both walker chains once and reports reads-used vs budget.
          First run after MTGA starts (or after clearing the cache) pays
          full discovery cost; subsequent runs hit the per-pid cache
          and drop two orders of magnitude.
        </p>

        <%= if @runs == [] do %>
          <p class="text-sm text-base-content/60 italic">
            No traces yet. Click <strong>Run trace</strong> with MTGA running.
          </p>
        <% else %>
          <div class="space-y-3 mt-2">
            <.walker_run_row :for={run <- @runs} run={run} />
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :run, :map, required: true

  defp walker_run_row(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-3">
      <div class="flex items-center justify-between text-xs text-base-content/60">
        <span>pid={@run.pid}</span>
        <span>{format_run_ts(@run.ts)}</span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mt-2">
        <.walker_chain_row label="match_info" chain={@run.info} summarise={&H.match_info_summary/1} />
        <.walker_chain_row
          label="match_board"
          chain={@run.board}
          summarise={&H.match_board_summary/1}
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :chain, :map, required: true
  attr :summarise, :any, required: true

  defp walker_chain_row(assigns) do
    ~H"""
    <div class="rounded border border-base-300 p-2">
      <div class="flex items-center gap-2">
        <code class="text-xs">{@label}</code>
        <span class={H.outcome_class(@chain.result)}>{H.format_outcome(@chain.result)}</span>
      </div>
      <div class="text-xs text-base-content/70 mt-1">
        <span class={H.band_class(H.usage_band(@chain.stats))}>
          {H.format_stats(@chain.stats)}
        </span>
        <span class="ml-2">{H.format_elapsed_ms(@chain.elapsed_ms)}</span>
      </div>
      <p :if={@summarise.(@chain.result) != ""} class="text-xs text-base-content/60 mt-1">
        {@summarise.(@chain.result)}
      </p>
    </div>
    """
  end

  attr :snapshot, :list, required: true

  defp cache_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title text-base">Discovery cache</h2>
          <div class="flex gap-2">
            <button type="button" phx-click="refresh_cache" class="btn btn-ghost btn-xs">
              Refresh
            </button>
            <button
              :if={@snapshot != []}
              type="button"
              phx-click="clear_cache"
              data-confirm="Drop the discovery cache for every pid?"
              class="btn btn-ghost btn-xs text-error"
            >
              Clear all
            </button>
          </div>
        </div>

        <p class="text-xs text-base-content/60">
          Per-pid cache of expensive class lookups (PAPA,
          MatchSceneManager, Dictionary&nbsp;<code class="text-xs">`2</code>).
          Cleared automatically when MTGA restarts (pid changes); clear
          manually here to force full re-discovery.
        </p>

        <%= if @snapshot == [] do %>
          <p class="text-sm text-base-content/60 italic mt-2">Cache is empty.</p>
        <% else %>
          <div class="overflow-x-auto mt-2">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>pid</th>
                  <th>cached slots</th>
                  <th class="text-right"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @snapshot}>
                  <td><code>{row.pid}</code></td>
                  <td>
                    <span :for={slot <- row.slots} class="badge badge-soft mr-1">{slot}</span>
                  </td>
                  <td class="text-right">
                    <button
                      type="button"
                      phx-click="invalidate_pid"
                      phx-value-pid={row.pid}
                      class="btn btn-ghost btn-xs"
                    >
                      Invalidate
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :needle, :string, required: true
  attr :results, :any, required: true

  defp class_search_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-base">Class search</h2>
        <p class="text-xs text-base-content/60">
          Substring match against every class name in every loaded
          assembly. Useful for finding new anchor candidates.
        </p>

        <form phx-submit="class_search" class="flex gap-2 mt-2">
          <input
            type="text"
            name="needle"
            value={@needle}
            placeholder="e.g. Inventory, MatchScene"
            class="input input-sm input-bordered flex-1"
          />
          <button type="submit" class="btn btn-primary btn-sm">Search</button>
        </form>

        <.lookup_results results={@results} columns={["assembly", "class", "addr"]}>
          <:row :let={row}>
            <% {assembly, class_name, addr} = row %>
            <td><code class="text-xs">{assembly}</code></td>
            <td><code class="text-xs">{class_name}</code></td>
            <td class="font-mono text-xs">0x{Integer.to_string(addr, 16)}</td>
          </:row>
        </.lookup_results>
      </div>
    </section>
    """
  end

  attr :name, :string, required: true
  attr :results, :any, required: true

  defp class_fields_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-base">Class fields</h2>
        <p class="text-xs text-base-content/60">
          Dump the field table for one class — offset, name, type tag,
          static flag. The output is what the walker uses to navigate
          chains.
        </p>

        <form phx-submit="class_fields" class="flex gap-2 mt-2">
          <input
            type="text"
            name="name"
            value={@name}
            placeholder="exact class name (e.g. PAPA)"
            class="input input-sm input-bordered flex-1"
          />
          <button type="submit" class="btn btn-primary btn-sm">Look up</button>
        </form>

        <.lookup_results results={@results} columns={["offset", "name", "type", "static?"]}>
          <:row :let={row}>
            <% {field_name, field_type, offset, is_static} = row %>
            <td class="font-mono text-xs">0x{Integer.to_string(offset, 16)}</td>
            <td><code class="text-xs">{field_name}</code></td>
            <td class="text-xs">{field_type}</td>
            <td>
              <span :if={is_static} class="badge badge-soft badge-info">static</span>
            </td>
          </:row>
        </.lookup_results>
      </div>
    </section>
    """
  end

  attr :results, :any, required: true

  defp assemblies_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title text-base">Loaded assemblies</h2>
          <button type="button" phx-click="list_assemblies" class="btn btn-ghost btn-xs">
            List
          </button>
        </div>
        <p class="text-xs text-base-content/60">
          Every assembly in MTGA's mono root domain. The walker scans
          this list to find anchor classes during cold-cache discovery
          (~222 entries on the current build).
        </p>

        <.lookup_results results={@results} columns={["assembly", "image addr"]}>
          <:row :let={row}>
            <% {name, addr} = row %>
            <td><code class="text-xs">{name}</code></td>
            <td class="font-mono text-xs">0x{Integer.to_string(addr, 16)}</td>
          </:row>
        </.lookup_results>
      </div>
    </section>
    """
  end

  attr :results, :any, required: true
  attr :columns, :list, required: true
  slot :row, required: true

  defp lookup_results(assigns) do
    ~H"""
    <%= case @results do %>
      <% nil -> %>
      <% {:error, msg} -> %>
        <p class="text-sm text-error mt-2">{msg}</p>
      <% {:ok, []} -> %>
        <p class="text-sm text-base-content/60 italic mt-2">No results.</p>
      <% {:ok, rows} -> %>
        <div class="overflow-x-auto mt-2">
          <table class="table table-xs">
            <thead>
              <tr>
                <th :for={col <- @columns}>{col}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- rows}>{render_slot(@row, row)}</tr>
            </tbody>
          </table>
        </div>
    <% end %>
    """
  end

  defp format_run_ts(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end
end
