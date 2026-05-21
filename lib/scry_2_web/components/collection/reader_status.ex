defmodule Scry2Web.Collection.ReaderStatus do
  @moduledoc """
  Header bar for `/collection`: refresh / disable / diagnostics controls,
  inline error alert, reader-health pill, build-change banner.

  Pure renderer. Host LiveView implements `phx-click` handlers
  `refresh`, `disable_reader`, `acknowledge_build_change`, and
  `verify_build_change`.
  """

  use Phoenix.Component
  use Scry2Web, :verified_routes

  alias Scry2.Collection.ReaderHealth

  import Scry2Web.Collection.BuildChangeBanner
  import Scry2Web.Collection.ReaderHealthPill

  attr :refreshing, :boolean, required: true
  attr :last_error, :any, required: true
  attr :build_change_status, :any, required: true
  attr :health, ReaderHealth, required: true
  attr :verify_state, :atom, default: :idle
  attr :verify_detail, :string, default: nil

  def reader_status(assigns) do
    ~H"""
    <div class="space-y-3" data-role="reader-status">
      <div class="flex flex-wrap items-center gap-3">
        <button
          class="btn btn-soft btn-primary btn-sm"
          phx-click="refresh"
          disabled={@refreshing}
        >
          <span :if={@refreshing}>Refreshing…</span>
          <span :if={not @refreshing}>Refresh now</span>
        </button>
        <button class="btn btn-ghost btn-sm" phx-click="disable_reader">
          Disable reader
        </button>
        <.link navigate={~p"/collection/diagnostics"} class="btn btn-ghost btn-sm">
          Diagnostics
        </.link>
        <.reader_health_pill health={@health} />
      </div>

      <div
        :if={@last_error}
        class="alert alert-soft alert-warning max-w-3xl"
        data-role="collection-error"
      >
        <span>{@last_error}</span>
      </div>

      <.build_change_banner
        status={@build_change_status}
        verify_state={@verify_state}
        verify_detail={@verify_detail}
      />
    </div>
    """
  end
end
