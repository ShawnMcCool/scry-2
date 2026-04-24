defmodule Scry2Web.SettingsLive.ApplyModal do
  @moduledoc """
  Full-viewport progress modal rendered while a self-update apply is in
  flight. Mirrors the media-centarr pattern: one row per visible phase,
  each row shows its own status icon (pending circle / active spinner /
  done check / failed X).

  Pure rendering — all event handling (dismiss, retry) lives on the host
  LiveView. The modal opens whenever `apply_phase != nil` and closes
  when the LiveView resets that assign.
  """
  use Scry2Web, :html

  alias Scry2Web.SettingsLive.ApplyHelpers

  attr :apply_phase, :atom, default: nil
  attr :apply_error, :any, default: nil
  attr :apply_failed_at, :atom, default: nil
  attr :apply_progress, :any, default: nil
  attr :release_tag, :string, default: nil

  def apply_modal(assigns) do
    ~H"""
    <div
      :if={ApplyHelpers.apply_visible?(@apply_phase)}
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="apply-modal-title"
    >
      <div class="w-full max-w-md rounded-2xl bg-base-100 shadow-2xl border border-base-300 p-6 space-y-5">
        <div class="space-y-1">
          <h3 id="apply-modal-title" class="text-lg font-semibold">
            Updating
            <span :if={@release_tag} class="font-mono text-sm text-base-content/60 ml-1">
              {@release_tag}
            </span>
          </h3>
          <p class="text-sm text-base-content/60">
            This usually takes under a minute. The app will restart when it finishes.
          </p>
        </div>

        <ol class="space-y-3">
          <.phase_row
            :for={phase <- ApplyHelpers.visible_phases()}
            phase={phase}
            current={@apply_phase}
            failed_at={@apply_failed_at}
            progress={@apply_progress}
          />
        </ol>

        <div
          :if={ApplyHelpers.apply_cancelable?(@apply_phase)}
          class="flex justify-end pt-2"
        >
          <button
            type="button"
            phx-click="cancel_update"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark-mini" class="size-4" /> Cancel update
          </button>
        </div>

        <div
          :if={@apply_phase == :failed}
          class="pt-4 border-t border-base-content/10 space-y-1"
        >
          <p class="text-sm text-error">
            {ApplyHelpers.apply_error_label(@apply_error)}
          </p>
          <p class="text-xs text-base-content/50">
            The running install is untouched.
          </p>
        </div>

        <div
          :if={@apply_phase in [:failed, :done]}
          class="flex justify-end gap-2 pt-2"
        >
          <button
            type="button"
            phx-click="dismiss_apply_modal"
            class="btn btn-ghost btn-sm"
          >
            Close
          </button>
          <button
            :if={@apply_phase == :failed}
            type="button"
            phx-click="updates_apply"
            class="btn btn-soft btn-primary btn-sm"
          >
            Retry
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :phase, :atom, required: true
  attr :current, :atom, required: true
  attr :failed_at, :atom, default: nil
  attr :progress, :any, default: nil

  defp phase_row(assigns) do
    state = ApplyHelpers.phase_state(assigns.phase, assigns.current, assigns.failed_at)
    assigns = assign(assigns, :state, state)

    ~H"""
    <li class="flex items-start gap-3">
      <div class="shrink-0 w-5 h-5 flex items-center justify-center">
        <div
          :if={@state == :pending}
          class="w-2.5 h-2.5 rounded-full border border-base-content/30"
        >
        </div>
        <.icon
          :if={@state == :active}
          name="hero-arrow-path-mini"
          class="size-4 animate-spin text-primary"
        />
        <.icon :if={@state == :done} name="hero-check-circle-mini" class="size-4 text-success" />
        <.icon :if={@state == :failed} name="hero-x-circle-mini" class="size-4 text-error" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline justify-between gap-2">
          <p class={ApplyHelpers.phase_text_class(@state)}>
            {ApplyHelpers.apply_phase_label(@phase)}
          </p>
          <span
            :if={@state == :active and @phase == :downloading and is_integer(@progress)}
            class="text-xs font-mono text-base-content/50"
          >
            {@progress}%
          </span>
        </div>
        <div
          :if={@state == :active and @phase == :downloading}
          class="h-1.5 mt-2 rounded bg-base-content/10 overflow-hidden"
        >
          <div
            class="h-full bg-primary rounded transition-[width] duration-150 ease-out"
            style={"width: #{@progress || 0}%"}
          >
          </div>
        </div>
      </div>
    </li>
    """
  end
end
