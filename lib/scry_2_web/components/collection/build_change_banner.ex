defmodule Scry2Web.Collection.BuildChangeBanner do
  @moduledoc """
  Renders an interactive verification banner when the latest collection
  snapshot stamps a different MTGA build than the user has previously
  verified.

  In addition to the existing **Acknowledge** action, the banner now
  exposes a **Run verification** button that runs a refresh via the
  host LiveView and surfaces the outcome (walker success / fallback /
  error / MTGA not running) inline. Once verified with full walker
  confidence, Acknowledge becomes the primary action.

  Pure renderer over a `Scry2.Collection.BuildChange.t()`. Renders
  nothing for `:no_data`, `:first_seen`, or `:current`. Emits
  `phx-click="acknowledge_build_change"` and
  `phx-click="verify_build_change"` events — host LiveViews must
  implement those handlers.
  """

  use Phoenix.Component
  use Scry2Web, :verified_routes

  attr :status, :any, required: true
  attr :verify_state, :atom, default: :idle
  attr :verify_detail, :string, default: nil

  def build_change_banner(%{status: {:changed, _prev, _current}} = assigns) do
    {:changed, prev, current} = assigns.status
    assigns = assign(assigns, prev: prev, current: current)

    ~H"""
    <div
      class={[
        "alert mt-3 flex flex-col items-stretch gap-2 sm:flex-row sm:items-start",
        alert_tone_class(@verify_state)
      ]}
      data-role="build-change-banner"
      data-verify-state={@verify_state}
    >
      <div class="flex-1 space-y-1">
        <h4 class="font-semibold">{heading(@verify_state)}</h4>
        <p class="text-sm">
          {body_text(@verify_state, @prev, @current, @verify_detail)}
        </p>
      </div>
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start">
        <.banner_buttons
          verify_state={@verify_state}
          verified_primary={@verify_state == :ok}
        />
      </div>
    </div>
    """
  end

  def build_change_banner(assigns), do: ~H""

  attr :verify_state, :atom, required: true
  attr :verified_primary, :boolean, required: true

  defp banner_buttons(%{verify_state: :running} = assigns) do
    ~H"""
    <button type="button" class="btn btn-soft btn-warning btn-sm" disabled>
      Reading from MTGA…
    </button>
    """
  end

  defp banner_buttons(%{verify_state: :fallback} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="acknowledge_build_change"
      class="btn btn-soft btn-warning btn-sm whitespace-nowrap"
    >
      Acknowledge anyway
    </button>
    <.link
      navigate={~p"/operations/mtga-memory"}
      class="btn btn-ghost btn-sm whitespace-nowrap"
    >
      Open diagnostics
    </.link>
    """
  end

  defp banner_buttons(%{verify_state: :failed} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="verify_build_change"
      class="btn btn-soft btn-error btn-sm whitespace-nowrap"
    >
      Try again
    </button>
    <.link
      navigate={~p"/operations/mtga-memory"}
      class="btn btn-ghost btn-sm whitespace-nowrap"
    >
      Open diagnostics
    </.link>
    <button
      type="button"
      phx-click="acknowledge_build_change"
      class="btn btn-ghost btn-sm whitespace-nowrap"
    >
      Acknowledge
    </button>
    """
  end

  defp banner_buttons(%{verify_state: :mtga_not_running} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="verify_build_change"
      class="btn btn-soft btn-neutral btn-sm whitespace-nowrap"
    >
      Try again
    </button>
    """
  end

  defp banner_buttons(%{verify_state: :ok} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="acknowledge_build_change"
      class="btn btn-soft btn-success btn-sm whitespace-nowrap"
    >
      Acknowledge — verified
    </button>
    """
  end

  defp banner_buttons(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="verify_build_change"
      class="btn btn-soft btn-warning btn-sm whitespace-nowrap"
    >
      Run verification
    </button>
    <button
      type="button"
      phx-click="acknowledge_build_change"
      class="btn btn-ghost btn-sm whitespace-nowrap"
    >
      Acknowledge
    </button>
    """
  end

  defp alert_tone_class(:ok), do: "alert-success"
  defp alert_tone_class(:fallback), do: "alert-warning"
  defp alert_tone_class(:failed), do: "alert-error"
  defp alert_tone_class(:mtga_not_running), do: "alert-info"
  defp alert_tone_class(_), do: "alert-warning"

  defp heading(:ok), do: "Memory reader verified"
  defp heading(:fallback), do: "Reader using a slower fallback"
  defp heading(:failed), do: "Memory reader couldn't read MTGA"
  defp heading(:mtga_not_running), do: "MTGA isn't running"
  defp heading(:running), do: "Verifying memory reader…"
  defp heading(_), do: "MTGA was updated"

  defp body_text(:ok, _prev, current, _detail) do
    "Scry2 read your collection from build #{current} using the full memory walker. Everything looks good."
  end

  defp body_text(:fallback, _prev, _current, _detail) do
    "Your collection is still being read, but Scry2 is using a slower fallback scanner — wallet, wildcards, and other walker-only data may be missing until Scry2 is updated to support this MTGA build."
  end

  defp body_text(:failed, _prev, current, detail) do
    base = "Scry2 couldn't navigate MTGA's memory on build #{current}."

    case detail do
      nil ->
        base <> " Scry2 likely needs to be updated to support this MTGA build."

      "" ->
        base <> " Scry2 likely needs to be updated to support this MTGA build."

      explanation ->
        base <>
          " " <> explanation <> " — Scry2 likely needs to be updated to support this MTGA build."
    end
  end

  defp body_text(:mtga_not_running, _prev, _current, _detail) do
    "MTGA isn't running right now. Start MTGA, sign in, then click Try again."
  end

  defp body_text(:running, _prev, _current, _detail) do
    "Reading your collection from MTGA…"
  end

  defp body_text(_idle, _prev, current, _detail) do
    "MTGA was updated to build #{current}. Run a quick check to confirm Scry2 can still read your collection from this build."
  end

  @doc """
  Translate a memory-reader failure atom (or tagged tuple) into a
  short, player-language phrase suitable for inline display in the
  banner body. Delegates to `Scry2.MtgaMemory.WalkError.translate/1` —
  the single mapping point shared with the reader self-test.
  """
  @spec translate_error(term()) :: String.t()
  defdelegate translate_error(reason), to: Scry2.MtgaMemory.WalkError, as: :translate
end
