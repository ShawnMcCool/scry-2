defmodule Scry2Web.SettingsLive.UpdatesCard do
  @moduledoc """
  Function component rendering the "Updates" card on the Settings page.

  Pure rendering driven entirely by assigns — no state, no PubSub. The
  host LiveView (`Scry2Web.SettingsLive`) handles subscription wiring
  and event handling; this module only turns a summary map into HEEx.
  """
  use Scry2Web, :html

  alias Scry2Web.SettingsLive.UpdatesHelpers

  attr :summary, :map, required: true
  attr :current_version, :string, required: true
  attr :last_check_at, :string, default: nil

  def updates_card(assigns) do
    ~H"""
    <section class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-base">Updates</h2>

        <div class="text-sm opacity-70">
          Running: <span class="font-mono">{@current_version}</span>
          <%= if @last_check_at do %>
            • Last checked {@last_check_at}
          <% end %>
        </div>

        <div class="mt-3">
          <%= case @summary.status do %>
            <% :no_data -> %>
              <p class="text-sm opacity-70">No release info yet. Click check to fetch.</p>
            <% :up_to_date -> %>
              <p class="text-sm">You are on the latest release.</p>
            <% :update_available -> %>
              <div class="flex items-center gap-2">
                <span class="badge badge-info badge-soft">
                  {@summary.version} available
                </span>
                <%= if @summary.html_url && @summary.html_url != "" do %>
                  <a class="link text-sm" href={@summary.html_url} target="_blank" rel="noopener">
                    Release notes
                  </a>
                <% end %>
              </div>
            <% :ahead_of_release -> %>
              <p class="text-sm opacity-70">Running a version newer than the latest release.</p>
            <% :invalid -> %>
              <p class="text-sm text-warning">Invalid release tag received from GitHub.</p>
          <% end %>
        </div>

        <%= if @summary[:applying] do %>
          <div class="mt-3 flex items-center gap-2">
            <progress class="progress progress-primary w-48"></progress>
            <span class="text-sm">{UpdatesHelpers.phase_label(@summary.applying)}</span>
          </div>
        <% end %>

        <%= if @summary[:last_error] do %>
          <p class="mt-3 text-xs text-warning">{@summary.last_error}</p>
        <% end %>

        <div class="card-actions mt-3 flex gap-2">
          <button
            class="btn btn-sm btn-ghost"
            phx-click="updates_check_now"
            disabled={@summary[:applying] not in [nil, :idle, :done, :failed]}
          >
            Check now
          </button>

          <%= if @summary.status == :update_available and @summary[:applying] in [nil, :idle, :failed] do %>
            <button class="btn btn-sm btn-soft btn-primary" phx-click="updates_apply">
              Apply update
            </button>
          <% end %>
        </div>
      </div>
    </section>
    """
  end
end
