defmodule Scry2Web.SettingsLive do
  @moduledoc """
  User-facing settings page.

  Tier 1 fields (MTGA `player_log_path`, `data_dir`, card synthesis
  `refresh_cron`) are editable and persist via `Scry2.Settings`, which
  overrides the corresponding TOML values at runtime through
  `Scry2.Settings.get_or_config/2`.

  Non-trivial logic lives in `Scry2Web.SettingsLive.Form` per ADR-013.
  """
  use Scry2Web, :live_view

  alias Scry2.Config
  alias Scry2.Events
  alias Scry2.MtgaLogIngestion.LocateLogFile
  alias Scry2.MtgaLogIngestion.Watcher
  alias Scry2.Settings
  alias Scry2Web.SettingsLive.Form

  @diagnostics_refresh_interval 2_000

  @player_log_path_key "mtga_logs_player_log_path"
  @data_dir_key "mtga_logs_data_dir"
  @refresh_cron_key "cards_refresh_cron"
  @poll_interval_key "mtga_logs_poll_interval_ms"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh_diagnostics, @diagnostics_refresh_interval)
    end

    {:ok,
     socket
     |> assign(:resolved_path, nil)
     |> assign(:candidates, [])
     |> assign(:config_path, Config.config_path())
     |> assign(:config_snapshot, %{})
     |> assign(:field_values, %{})
     |> assign(:field_errors, %{})
     |> assign(:editing, %{})
     |> assign(:diagnostics, empty_diagnostics())}
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
      cards_scryfall_bulk_url: Config.get(:cards_scryfall_bulk_url),
      start_watcher: Config.get(:start_watcher),
      start_importer: Config.get(:start_importer)
    }

    field_values = %{
      player_log_path: current_value(@player_log_path_key, :mtga_logs_player_log_path),
      data_dir: current_value(@data_dir_key, :mtga_data_dir),
      refresh_cron: current_value(@refresh_cron_key, :cards_refresh_cron),
      poll_interval_ms: current_value(@poll_interval_key, :mtga_logs_poll_interval_ms)
    }

    {:noreply,
     socket
     |> assign(:resolved_path, resolved)
     |> assign(:candidates, LocateLogFile.default_candidates())
     |> assign(:config_snapshot, snapshot)
     |> assign(:field_values, field_values)
     |> assign(:field_errors, %{})
     |> assign(:diagnostics, Events.inspect_ingestion_state())}
  end

  @impl true
  def handle_info(:refresh_diagnostics, socket) do
    Process.send_after(self(), :refresh_diagnostics, @diagnostics_refresh_interval)
    {:noreply, assign(socket, :diagnostics, Events.inspect_ingestion_state())}
  end

  @impl true
  def handle_event("start_edit", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    {:noreply, start_editing(socket, field_atom)}
  end

  def handle_event("cancel_edit", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    {:noreply,
     socket
     |> put_field_value(field_atom, stored_value(field_atom))
     |> clear_field_error(field_atom)
     |> stop_editing(field_atom)}
  end

  def handle_event("save_player_log_path", %{"value" => value}, socket) do
    case Form.validate_player_log_path(value) do
      {:ok, expanded} ->
        Settings.put!(@player_log_path_key, expanded)
        Watcher.reload_path()

        {:noreply,
         socket
         |> put_field_value(:player_log_path, expanded)
         |> clear_field_error(:player_log_path)
         |> stop_editing(:player_log_path)
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
         |> start_editing(:player_log_path)
         |> put_flash(:info, "Auto-detected: #{path}. Click Save to apply.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> start_editing(:player_log_path)
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
         |> stop_editing(:data_dir)
         |> put_flash(:info, "MTGA data directory saved.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_field_value(:data_dir, value)
         |> put_field_error(:data_dir, Form.error_message(:data_dir, reason))}
    end
  end

  def handle_event("save_poll_interval_ms", %{"value" => value}, socket) do
    case Form.validate_poll_interval_ms(value) do
      {:ok, int} ->
        Settings.put!(@poll_interval_key, int)

        {:noreply,
         socket
         |> put_field_value(:poll_interval_ms, Integer.to_string(int))
         |> clear_field_error(:poll_interval_ms)
         |> put_flash(:info, "Poll interval saved — watcher will pick up the new value.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_field_value(:poll_interval_ms, value)
         |> put_field_error(:poll_interval_ms, Form.error_message(:poll_interval_ms, reason))}
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
         |> stop_editing(:refresh_cron)
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

  defp empty_diagnostics do
    %{
      last_raw_event_id: 0,
      session: %{
        self_user_id: nil,
        player_id: nil,
        current_session_id: nil,
        constructed_rank: nil,
        limited_rank: nil
      },
      match: %{
        current_match_id: nil,
        current_game_number: nil,
        last_deck_name: nil,
        on_play_for_current_game: nil,
        pending_deck?: false
      }
    }
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

  defp start_editing(socket, field) do
    assign(socket, :editing, Map.put(socket.assigns.editing, field, true))
  end

  defp stop_editing(socket, field) do
    assign(socket, :editing, Map.delete(socket.assigns.editing, field))
  end

  defp stored_value(:player_log_path),
    do: current_value(@player_log_path_key, :mtga_logs_player_log_path)

  defp stored_value(:data_dir), do: current_value(@data_dir_key, :mtga_data_dir)
  defp stored_value(:refresh_cron), do: current_value(@refresh_cron_key, :cards_refresh_cron)

  defp stored_value(:poll_interval_ms),
    do: current_value(@poll_interval_key, :mtga_logs_poll_interval_ms)

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

      <div class="max-w-3xl space-y-6">
        <section class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-base">MTGA Player.log path</h2>
            <p :if={@resolved_path} class="text-sm">
              <span class="badge badge-soft badge-success">Resolved</span>
              <code class="ml-2 break-all">{@resolved_path}</code>
            </p>
            <p :if={is_nil(@resolved_path)} class="text-sm">
              <span class="badge badge-soft badge-warning">Not found</span>
              Scry&nbsp;2 could not locate <code>Player.log</code>.
            </p>

            <button
              :if={!@editing[:player_log_path]}
              type="button"
              phx-click="start_edit"
              phx-value-field="player_log_path"
              class="link link-primary text-sm self-start mt-2"
            >
              Change log path
            </button>

            <div :if={@editing[:player_log_path]} class="mt-2">
              <p class="text-sm text-base-content/70">
                Enter the absolute path below, or click <em>Auto-detect</em> to scan the
                standard Steam/Proton/Lutris/Bottles locations.
              </p>

              <.setting_form
                field={:player_log_path}
                label="Path to Player.log"
                value={@field_values.player_log_path}
                error={@field_errors[:player_log_path]}
                save_event="save_player_log_path"
                help="Absolute path to MTGA's Player.log."
              >
                <:extra_buttons>
                  <button
                    type="button"
                    phx-click="auto_detect_player_log_path"
                    class="btn btn-ghost btn-sm"
                  >
                    Auto-detect
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    phx-value-field="player_log_path"
                    class="btn btn-ghost btn-sm"
                  >
                    Cancel
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
          </div>
        </section>

        <section class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-base">MTGA data directory</h2>
            <p class="text-sm">
              <span :if={@field_values.data_dir not in [nil, ""]}>
                <code class="break-all">{@field_values.data_dir}</code>
              </span>
              <span :if={@field_values.data_dir in [nil, ""]} class="text-base-content/60">
                Not set — auto-derived from the MTGA installation path.
              </span>
            </p>

            <button
              :if={!@editing[:data_dir]}
              type="button"
              phx-click="start_edit"
              phx-value-field="data_dir"
              class="link link-primary text-sm self-start mt-2"
            >
              Change data directory
            </button>

            <div :if={@editing[:data_dir]} class="mt-2">
              <p class="text-sm text-base-content/70">
                Directory containing <code>Raw_CardDatabase_*.mtga</code>.
              </p>

              <.setting_form
                field={:data_dir}
                label="Raw/ directory"
                value={@field_values.data_dir}
                error={@field_errors[:data_dir]}
                save_event="save_data_dir"
                help="Example: ~/.local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"
              >
                <:extra_buttons>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    phx-value-field="data_dir"
                    class="btn btn-ghost btn-sm"
                  >
                    Cancel
                  </button>
                </:extra_buttons>
              </.setting_form>
            </div>
          </div>
        </section>

        <section class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-base">Card refresh schedule</h2>
            <p class="text-sm">
              <span :if={@field_values.refresh_cron not in [nil, ""]}>
                <code>{@field_values.refresh_cron}</code>
              </span>
              <span :if={@field_values.refresh_cron in [nil, ""]} class="text-base-content/60">
                Not set.
              </span>
            </p>

            <button
              :if={!@editing[:refresh_cron]}
              type="button"
              phx-click="start_edit"
              phx-value-field="refresh_cron"
              class="link link-primary text-sm self-start mt-2"
            >
              Change refresh schedule
            </button>

            <div :if={@editing[:refresh_cron]} class="mt-2">
              <p class="text-sm text-base-content/70">
                Cron expression for the daily card synthesis job
                (<code>PeriodicallySynthesizeCards</code>).
                <span class="badge badge-soft badge-info">Restart required</span>
                Changes take effect on next app boot.
              </p>

              <.setting_form
                field={:refresh_cron}
                label="Cron expression"
                value={@field_values.refresh_cron}
                error={@field_errors[:refresh_cron]}
                save_event="save_refresh_cron"
                help="Standard 5-field cron or shorthand like @daily."
              >
                <:extra_buttons>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    phx-value-field="refresh_cron"
                    class="btn btn-ghost btn-sm"
                  >
                    Cancel
                  </button>
                </:extra_buttons>
              </.setting_form>
            </div>
          </div>
        </section>

        <section class="card bg-base-200">
          <div class="card-body">
            <details>
              <summary class="card-title text-base cursor-pointer">
                Advanced
              </summary>
              <div class="mt-3">
                <h3 class="text-sm font-semibold">Watcher drain interval</h3>
                <p class="text-xs text-base-content/70 mt-1">
                  Debounce window after a <code>Player.log</code> modification before
                  draining new bytes. Shorter = lower latency, longer = more burst
                  coalescing. Range: 100–10000 ms.
                </p>

                <.setting_form
                  field={:poll_interval_ms}
                  label="poll_interval_ms"
                  value={@field_values.poll_interval_ms}
                  error={@field_errors[:poll_interval_ms]}
                  save_event="save_poll_interval_ms"
                  help="Default: 500 ms"
                />
              </div>
            </details>
          </div>
        </section>

        <section class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-base">Ingestion diagnostics</h2>
            <p class="text-xs text-base-content/60">
              Live projection of <code>Scry2.Events.IngestionState</code>. Refreshes every 2&nbsp;seconds.
            </p>
            <div class="overflow-x-auto mt-2">
              <table class="table table-xs">
                <tbody>
                  <tr>
                    <td class="font-mono text-xs">last_raw_event_id</td>
                    <td class="font-mono text-xs">{@diagnostics.last_raw_event_id}</td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">session.self_user_id</td>
                    <td class="font-mono text-xs break-all">
                      {@diagnostics.session.self_user_id || "—"}
                    </td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">session.player_id</td>
                    <td class="font-mono text-xs">{@diagnostics.session.player_id || "—"}</td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">session.current_session_id</td>
                    <td class="font-mono text-xs break-all">
                      {@diagnostics.session.current_session_id || "—"}
                    </td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">session.constructed_rank</td>
                    <td class="font-mono text-xs">{@diagnostics.session.constructed_rank || "—"}</td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">session.limited_rank</td>
                    <td class="font-mono text-xs">{@diagnostics.session.limited_rank || "—"}</td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">match.current_match_id</td>
                    <td class="font-mono text-xs break-all">
                      {@diagnostics.match.current_match_id || "—"}
                    </td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">match.current_game_number</td>
                    <td class="font-mono text-xs">{@diagnostics.match.current_game_number || "—"}</td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">match.last_deck_name</td>
                    <td class="font-mono text-xs break-all">
                      {@diagnostics.match.last_deck_name || "—"}
                    </td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">match.on_play_for_current_game</td>
                    <td class="font-mono text-xs">
                      {case @diagnostics.match.on_play_for_current_game do
                        nil -> "—"
                        true -> "true"
                        false -> "false"
                      end}
                    </td>
                  </tr>
                  <tr>
                    <td class="font-mono text-xs">match.pending_deck?</td>
                    <td class="font-mono text-xs">{to_string(@diagnostics.match.pending_deck?)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
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
      </div>
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
