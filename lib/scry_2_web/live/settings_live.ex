defmodule Scry2Web.SettingsLive do
  use Scry2Web, :live_view

  alias Scry2.Config
  alias Scry2.MtgaLogs.PathResolver

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:resolved_path, nil)
     |> assign(:candidates, [])
     |> assign(:config_snapshot, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    resolved =
      case PathResolver.resolve() do
        {:ok, path} -> path
        {:error, :not_found} -> nil
      end

    snapshot = %{
      database_path: Config.get(:database_path),
      mtga_logs_player_log_path: Config.get(:mtga_logs_player_log_path),
      mtga_logs_poll_interval_ms: Config.get(:mtga_logs_poll_interval_ms),
      cards_lands17_url: Config.get(:cards_lands17_url),
      cards_refresh_cron: Config.get(:cards_refresh_cron),
      start_watcher: Config.get(:start_watcher),
      start_importer: Config.get(:start_importer)
    }

    {:noreply,
     socket
     |> assign(:resolved_path, resolved)
     |> assign(:candidates, PathResolver.default_candidates())
     |> assign(:config_snapshot, snapshot)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold">Settings</h1>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">MTGA log file</h2>
          <p :if={@resolved_path} class="text-sm">
            <span class="badge badge-success">Resolved</span>
            <code class="ml-2 break-all">{@resolved_path}</code>
          </p>
          <p :if={is_nil(@resolved_path)} class="text-sm">
            <span class="badge badge-warning">Not found</span>
            Scry2 checked the following locations and found no matching file.
            Set <code>[mtga_logs] player_log_path</code>
            in <code>~/.config/scry_2/config.toml</code>
            to override.
          </p>
          <details class="mt-2">
            <summary class="text-xs text-base-content/60 cursor-pointer">
              Candidate paths scanned
            </summary>
            <ol class="text-xs mt-2 list-decimal list-inside space-y-1">
              <li :for={path <- @candidates}><code class="break-all">{path}</code></li>
            </ol>
          </details>
        </div>
      </section>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">Effective configuration</h2>
          <p class="text-xs text-base-content/60">
            Read from <code>~/.config/scry_2/config.toml</code> merged with built-in defaults.
          </p>
          <div class="overflow-x-auto mt-2">
            <table class="table table-xs">
              <tbody>
                <tr :for={{key, value} <- @config_snapshot}>
                  <td class="font-mono text-xs">{key}</td>
                  <td class="font-mono text-xs break-all">{inspect(value)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
