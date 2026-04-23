defmodule Scry2Web.SettingsLive.ServiceCard do
  @moduledoc """
  Function component rendering the "Service" card on the Settings page.

  Pure rendering driven by assigns. The card surfaces whichever
  `Scry2.Service` backend is supervising the BEAM (systemd unit, the
  Go tray, or unmanaged), shows backend-reported state (active /
  installed / enabled when applicable), and exposes Restart / Stop
  buttons gated by the backend's `capabilities`.

  The host LiveView wires up `service_restart` and `service_stop`
  events; this module never calls into `Scry2.Service` directly.
  """
  use Scry2Web, :html

  attr :name, :string, required: true
  attr :state, :map, required: true
  attr :capabilities, :map, required: true
  attr :error, :string, default: nil

  def service_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-base">Service</h2>

        <div class="text-sm">
          Supervisor: <span class="font-mono">{@name}</span>
        </div>

        <div class="mt-2 flex flex-wrap gap-2 text-xs">
          <span class={[
            "badge badge-sm badge-soft",
            if(@state[:active], do: "badge-success", else: "badge-warning")
          ]}>
            {if @state[:active], do: "active", else: "inactive"}
          </span>

          <%= if Map.has_key?(@state, :unit_installed) do %>
            <span class={[
              "badge badge-sm badge-soft",
              if(@state.unit_installed, do: "badge-info", else: "badge-warning")
            ]}>
              unit {if @state.unit_installed, do: "installed", else: "missing"}
            </span>
          <% end %>

          <%= if Map.has_key?(@state, :enabled) do %>
            <span class={[
              "badge badge-sm badge-soft",
              if(@state.enabled, do: "badge-info", else: "badge-ghost")
            ]}>
              {if @state.enabled, do: "enabled", else: "not enabled"}
            </span>
          <% end %>

          <%= if Map.has_key?(@state, :systemd_available) and not @state.systemd_available do %>
            <span class="badge badge-sm badge-soft badge-warning">
              systemctl unavailable
            </span>
          <% end %>
        </div>

        <%= if @state[:backend] == :unmanaged do %>
          <p class="mt-3 text-xs opacity-70">
            Running standalone (no supervisor detected). Restart the BEAM manually
            to apply changes.
          </p>
        <% end %>

        <%= if @state[:backend] == :tray do %>
          <p class="mt-3 text-xs opacity-70">
            Managed by the desktop tray. Restart triggers a clean <code>System.stop</code>; the tray watchdog respawns within ~12s.
          </p>
        <% end %>

        <%= if @error do %>
          <p class="mt-3 text-xs text-warning">{@error}</p>
        <% end %>

        <div class="card-actions mt-3 flex gap-2">
          <%= if @capabilities.can_restart do %>
            <button
              class="btn btn-sm btn-soft btn-primary"
              phx-click="service_restart"
              data-confirm="Restart the backend now?"
            >
              Restart
            </button>
          <% end %>

          <%= if @capabilities.can_stop do %>
            <button
              class="btn btn-sm btn-soft btn-warning"
              phx-click="service_stop"
              data-confirm="Stop the backend? It will not auto-restart."
            >
              Stop
            </button>
          <% end %>
        </div>
      </div>
    </section>
    """
  end
end
