defmodule Scry2Web.SettingsLive do
  @moduledoc """
  User-facing settings page.

  Tier 1 fields (MTGA `player_log_path`, `data_dir`, 17lands
  `refresh_cron`) are editable and persist via `Scry2.Settings`, which
  overrides the corresponding TOML values at runtime through
  `Scry2.Settings.get_or_config/2`.

  Non-trivial logic lives in `Scry2Web.SettingsLive.Form` per ADR-013.
  """
  use Scry2Web, :live_view

  alias Scry2.Config
  alias Scry2.MtgaLogIngestion.LocateLogFile
  alias Scry2.MtgaLogIngestion.Watcher
  alias Scry2.Settings
  alias Scry2Web.SettingsLive.Form

  @player_log_path_key "mtga_logs_player_log_path"
  @data_dir_key "mtga_logs_data_dir"
  @refresh_cron_key "cards_refresh_cron"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:resolved_path, nil)
     |> assign(:candidates, [])
     |> assign(:config_path, Config.config_path())
     |> assign(:config_snapshot, %{})
     |> assign(:field_values, %{})
     |> assign(:field_errors, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    resolved =
      case LocateLogFile.resolve() do
        {:ok, path} -> path
        {:error, :not_found} -> nil
      end

    snapshot = %{
      database_path: Config.get(:database_path),
      cache_dir: Config.get(:cache_dir),
      cards_lands17_url: Config.get(:cards_lands17_url),
      cards_scryfall_bulk_url: Config.get(:cards_scryfall_bulk_url),
      start_watcher: Config.get(:start_watcher),
      start_importer: Config.get(:start_importer)
    }

    field_values = %{
      player_log_path: current_value(@player_log_path_key, :mtga_logs_player_log_path),
      data_dir: current_value(@data_dir_key, :mtga_data_dir),
      refresh_cron: current_value(@refresh_cron_key, :cards_refresh_cron)
    }

    {:noreply,
     socket
     |> assign(:resolved_path, resolved)
     |> assign(:candidates, LocateLogFile.default_candidates())
     |> assign(:config_snapshot, snapshot)
     |> assign(:field_values, field_values)
     |> assign(:field_errors, %{})}
  end

  @impl true
  def handle_event("save_player_log_path", %{"value" => value}, socket) do
    case Form.validate_player_log_path(value) do
      {:ok, expanded} ->
        Settings.put!(@player_log_path_key, expanded)
        Watcher.reload_path()

        {:noreply,
         socket
         |> put_field_value(:player_log_path, expanded)
         |> clear_field_error(:player_log_path)
         |> assign(:resolved_path, expanded)
         |> put_flash(:info, "Player.log path saved — watcher reloaded.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_field_value(:player_log_path, value)
         |> put_field_error(:player_log_path, Form.error_message(:player_log_path, reason))}
    end
  end

  def handle_event("auto_detect_player_log_path", _params, socket) do
    case LocateLogFile.resolve() do
      {:ok, path} ->
        {:noreply,
         socket
         |> put_field_value(:player_log_path, path)
         |> clear_field_error(:player_log_path)
         |> put_flash(:info, "Auto-detected: #{path}. Click Save to apply.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_field_error(
           :player_log_path,
           "Could not auto-detect Player.log — none of the known candidate paths exist."
         )}
    end
  end

  def handle_event("save_data_dir", %{"value" => value}, socket) do
    case Form.validate_data_dir(value) do
      {:ok, expanded} ->
        Settings.put!(@data_dir_key, expanded)

        {:noreply,
         socket
         |> put_field_value(:data_dir, expanded)
         |> clear_field_error(:data_dir)
         |> put_flash(:info, "MTGA data directory saved.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_field_value(:data_dir, value)
         |> put_field_error(:data_dir, Form.error_message(:data_dir, reason))}
    end
  end

  def handle_event("save_refresh_cron", %{"value" => value}, socket) do
    case Form.validate_refresh_cron(value) do
      {:ok, trimmed} ->
        Settings.put!(@refresh_cron_key, trimmed)

        {:noreply,
         socket
         |> put_field_value(:refresh_cron, trimmed)
         |> clear_field_error(:refresh_cron)
         |> put_flash(
           :info,
           "Refresh cron saved — restart the app for the new schedule to take effect."
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_field_value(:refresh_cron, value)
         |> put_field_error(:refresh_cron, Form.error_message(:refresh_cron, reason))}
    end
  end

  defp current_value(settings_key, config_key) do
    case Settings.get_or_config(settings_key, config_key) do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp put_field_value(socket, field, value) do
    assign(socket, :field_values, Map.put(socket.assigns.field_values, field, value))
  end

  defp put_field_error(socket, field, message) do
    assign(socket, :field_errors, Map.put(socket.assigns.field_errors, field, message))
  end

  defp clear_field_error(socket, field) do
    assign(socket, :field_errors, Map.delete(socket.assigns.field_errors, field))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold">Settings</h1>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">MTGA Player.log path</h2>
          <p :if={@resolved_path} class="text-sm">
            <span class="badge badge-soft badge-success">Resolved</span>
            <code class="ml-2 break-all">{@resolved_path}</code>
          </p>
          <p :if={is_nil(@resolved_path)} class="text-sm">
            <span class="badge badge-soft badge-warning">Not found</span>
            Scry&nbsp;2 could not locate <code>Player.log</code>. Enter the path
            below or click <em>Auto-detect</em>.
          </p>

          <.setting_form
            field={:player_log_path}
            label="Path to Player.log"
            value={@field_values.player_log_path}
            error={@field_errors[:player_log_path]}
            save_event="save_player_log_path"
            help="Absolute path to MTGA's Player.log. Auto-detect scans the standard Steam/Proton/Lutris/Bottles locations."
          >
            <:extra_buttons>
              <button
                type="button"
                phx-click="auto_detect_player_log_path"
                class="btn btn-ghost btn-sm"
              >
                Auto-detect
              </button>
            </:extra_buttons>
          </.setting_form>

          <details class="mt-2">
            <summary class="text-xs text-base-content/60 cursor-pointer">
              Candidate paths scanned by auto-detect
            </summary>
            <ol class="text-xs mt-2 list-decimal list-inside space-y-1">
              <li :for={path <- @candidates}><code class="break-all">{path}</code></li>
            </ol>
          </details>
        </div>
      </section>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">MTGA data directory</h2>
          <p class="text-sm text-base-content/70">
            Directory containing <code>Raw_CardDatabase_*.mtga</code>. Leave
            blank to let Scry&nbsp;2 derive it from the MTGA installation path.
          </p>

          <.setting_form
            field={:data_dir}
            label="Raw/ directory"
            value={@field_values.data_dir}
            error={@field_errors[:data_dir]}
            save_event="save_data_dir"
            help="Example: ~/.local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"
          />
        </div>
      </section>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">17lands refresh schedule</h2>
          <p class="text-sm text-base-content/70">
            Cron expression for the daily <code>cards.csv</code>
            refresh job. <span class="badge badge-soft badge-info">Restart required</span>
            Changes take effect on next app boot.
          </p>

          <.setting_form
            field={:refresh_cron}
            label="Cron expression"
            value={@field_values.refresh_cron}
            error={@field_errors[:refresh_cron]}
            save_event="save_refresh_cron"
            help="Standard 5-field cron or shorthand like @daily."
          />
        </div>
      </section>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">Effective configuration (read-only)</h2>
          <p class="text-xs text-base-content/60">
            Infrastructure keys that live only in <code>{@config_path}</code>.
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

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :error, :string, default: nil
  attr :save_event, :string, required: true
  attr :help, :string, default: nil
  slot :extra_buttons

  defp setting_form(assigns) do
    ~H"""
    <form phx-submit={@save_event} class="mt-3 space-y-2">
      <label class="text-xs text-base-content/60">{@label}</label>
      <div class="flex gap-2">
        <input
          type="text"
          name="value"
          value={@value}
          class={["input input-sm input-bordered flex-1 font-mono text-xs", @error && "input-error"]}
          autocomplete="off"
          spellcheck="false"
        />
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        {render_slot(@extra_buttons)}
      </div>
      <p :if={@error} class="text-xs text-error">{@error}</p>
      <p :if={@help && is_nil(@error)} class="text-xs text-base-content/50">{@help}</p>
    </form>
    """
  end
end
