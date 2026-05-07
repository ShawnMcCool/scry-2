defmodule Scry2Web.Collection.BuildChangeBanner do
  @moduledoc """
  Renders an acknowledgement banner when the latest collection snapshot
  stamps a different MTGA build than the user has previously verified.

  Pure renderer over a `Scry2.Collection.BuildChange.t()`. Renders nothing
  for `:no_data`, `:first_seen`, or `:current`. Emits a
  `phx-click="acknowledge_build_change"` event when the user dismisses
  the banner — host LiveViews must implement that handler.
  """

  use Phoenix.Component

  attr :status, :any, required: true

  def build_change_banner(%{status: {:changed, _prev, _current}} = assigns) do
    {:changed, prev, current} = assigns.status
    assigns = assign(assigns, prev: prev, current: current)

    ~H"""
    <div
      class="alert alert-warning mt-3 flex flex-col items-stretch gap-2 sm:flex-row sm:items-start"
      data-role="build-change-banner"
    >
      <div class="flex-1">
        <h4 class="font-semibold">MTGA was updated</h4>
        <p class="text-sm">
          Scry's memory reader was last verified against build <code class="text-xs">{@prev}</code>. The latest collection snapshot stamps <code class="text-xs">{@current}</code>. Open your collection in MTGA
          and refresh to confirm cards are still being read correctly. If everything
          looks right, acknowledge to silence this alert until the next MTGA update.
        </p>
      </div>
      <button
        type="button"
        phx-click="acknowledge_build_change"
        class="btn btn-soft btn-warning btn-sm whitespace-nowrap"
      >
        Acknowledge
      </button>
    </div>
    """
  end

  def build_change_banner(assigns), do: ~H""
end
