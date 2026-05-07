defmodule Scry2Web.Collection.DisabledBanner do
  @moduledoc """
  Renders the consent CTA shown when the memory reader is off (ADR 034).

  Emits `phx-click="enable_reader"` — host LiveView implements the handler.
  """

  use Phoenix.Component

  def disabled_banner(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="collection-disabled">
      <div class="card-body space-y-4">
        <h2 class="card-title">Memory reader is off</h2>
        <p class="text-sm opacity-80">
          Scry&nbsp;2 can read your full MTGA collection (including cards you have never
          played) directly from the running MTGA process. This requires scanning the
          game's memory while it is running.
        </p>
        <p class="text-sm opacity-80">
          No files are modified. No data leaves your machine. You can disable the reader
          at any time; nothing else in Scry&nbsp;2 depends on it.
        </p>
        <div class="card-actions justify-end">
          <button class="btn btn-primary btn-sm" phx-click="enable_reader">
            Enable memory reader
          </button>
        </div>
      </div>
    </div>
    """
  end
end
