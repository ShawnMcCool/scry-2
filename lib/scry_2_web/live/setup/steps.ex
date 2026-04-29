defmodule Scry2Web.SetupLive.Steps do
  @moduledoc """
  Step renderers for the first-run setup tour.

  Each component is stateless — it renders based on its assigns and
  emits `phx-click` events the parent `Scry2Web.SetupLive` handles.
  All informational by default; fallback action controls (manual path
  input, retry buttons) only render when a step has a live failure.

  Tour shape (5 steps):
    1. `welcome_step/1` — one paragraph explaining Scry2 and asking
       the user to enable MTGA's "Detailed Logs (Plugin Support)".
    2. `locate_log_step/1` — shows the auto-detected Player.log path,
       or a manual text input if auto-resolution failed.
    3. `card_status_step/1` — informational status of card synthesis +
       Scryfall imports, plus the cron schedule. No actions here — card
       data auto-imports on boot.
    4. `verify_events_step/1` — live-waits for the first raw event.
       "Launch MTGA now" prompt; skippable.
    5. `done_step/1` — summary + link to the dashboard.
  """
  use Phoenix.Component

  import Scry2Web.CoreComponents

  alias Scry2.SetupFlow.State

  # ── Step 1: Welcome ──────────────────────────────────────────────────────

  attr :state, State, required: true

  def welcome_step(assigns) do
    ~H"""
    <div class="space-y-3 text-sm leading-relaxed text-base-content/80">
      <h2 class="text-lg font-semibold text-base-content">Welcome to Scry 2</h2>

      <p>
        Scry 2 watches MTG Arena's log file in the background, records
        every match, draft, and game you play, and lets you explore
        your play history on this site.
      </p>

      <div class="alert alert-soft alert-info text-sm">
        <.icon name="hero-light-bulb" class="size-4" />
        <div>
          <p class="font-semibold">
            Enable <em>Detailed Logs (Plugin Support)</em> in MTGA now
          </p>
          <p class="text-xs mt-1">
            Without this setting, <code>Player.log</code>
            only contains plain-text entries and Scry 2 can't parse any events.
            In MTGA, go to <strong>Options → View Account</strong>
            and enable <strong>Detailed Logs (Plugin Support)</strong>.
            You only need to do this once.
          </p>
        </div>
      </div>

      <p class="text-xs text-base-content/60">
        This walkthrough will take a minute. Everything Scry 2 needs is
        already being set up automatically in the background — this tour
        just shows you what's happening.
      </p>
    </div>
    """
  end

  # ── Step 2: Locate Player.log ─────────────────────────────────────────────

  attr :state, State, required: true

  def locate_log_step(assigns) do
    ~H"""
    <div class="space-y-3 text-sm leading-relaxed text-base-content/80">
      <h2 class="text-lg font-semibold text-base-content">Locate your Player.log</h2>

      <p>
        Scry 2 scans the common install locations for MTGA's <code>Player.log</code>
        file. If yours is somewhere unusual, you can enter the path manually.
      </p>

      <div :if={@state.detected_path} class="alert alert-soft alert-success text-sm">
        <.icon name="hero-check-circle" class="size-4" />
        <div>
          <p class="font-semibold">Found automatically</p>
          <p class="text-xs break-all mt-1">
            <code>{@state.detected_path}</code>
          </p>
        </div>
      </div>

      <div :if={is_nil(@state.detected_path)} class="space-y-3">
        <div class="alert alert-soft alert-warning text-sm">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          <div>
            <p class="font-semibold">Couldn't find Player.log automatically</p>
            <p class="text-xs mt-1">
              This usually means MTGA isn't installed, or it lives in a
              custom location. If you've already launched MTGA at least once
              with Detailed Logs enabled, paste the path below.
            </p>
          </div>
        </div>

        <form phx-submit="save_manual_path" class="space-y-2">
          <label class="label py-1">
            <span class="label-text text-xs">Path to Player.log</span>
          </label>
          <input
            type="text"
            name="path"
            value={@state.manual_path || ""}
            placeholder="/home/you/.wine/.../Player.log"
            class="input input-bordered input-sm w-full font-mono text-xs"
            phx-debounce="500"
          />
          <p :if={@state.manual_path_error} class="text-error text-xs">
            {@state.manual_path_error}
          </p>
          <button
            type="submit"
            class="btn btn-soft btn-primary btn-sm border border-primary/40"
          >
            Try this path
          </button>
        </form>

        <p class="text-xs text-base-content/60">
          You can also skip this step and fix it later from the health screen.
        </p>
      </div>
    </div>
    """
  end

  # ── Step 3: Card data status ──────────────────────────────────────────────

  attr :state, State, required: true
  attr :synthesized_count, :integer, required: true
  attr :scryfall_count, :integer, required: true
  attr :synthesized_updated_at, :any, required: true
  attr :scryfall_updated_at, :any, required: true

  def card_status_step(assigns) do
    ~H"""
    <div class="space-y-3 text-sm leading-relaxed text-base-content/80">
      <h2 class="text-lg font-semibold text-base-content">Card reference data</h2>

      <p>
        Scry 2 reads card identity from your local MTGA install and pulls oracle
        text and card images from <a href="https://scryfall.com" target="_blank" class="link">Scryfall</a>.
        Both sources are synthesised into a single read model that powers card
        lookups. This happens automatically on first launch and refreshes on a
        schedule after that — you don't need to do anything.
      </p>

      <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
        <.card_source_row
          label="Synthesised cards"
          count={@synthesized_count}
          updated_at={@synthesized_updated_at}
          schedule="Daily at 05:30 UTC"
        />
        <.card_source_row
          label="Scryfall"
          count={@scryfall_count}
          updated_at={@scryfall_updated_at}
          schedule="Weekly on Sundays at 05:00 UTC"
        />
      </div>

      <p class="text-xs text-base-content/60">
        Don't worry if the counts are still zero — the import may still be running
        in the background. You can continue and come back to the health screen to
        verify it completes.
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :updated_at, :any, required: true
  attr :schedule, :string, required: true

  defp card_source_row(assigns) do
    ~H"""
    <div class="rounded bg-base-300/40 px-3 py-2">
      <div class="flex items-center justify-between gap-2">
        <h3 class="font-semibold text-sm text-base-content">{@label}</h3>
        <.status_badge count={@count} />
      </div>
      <p class="text-xs text-base-content/60 mt-0.5">
        <span :if={@count > 0}>{@count} rows</span>
        <span :if={@count == 0}>Import in progress…</span>
        <span :if={@updated_at}>
          · {Calendar.strftime(@updated_at, "%Y-%m-%d %H:%M UTC")}
        </span>
      </p>
      <p class="text-xs text-base-content/40">{@schedule}</p>
    </div>
    """
  end

  attr :count, :integer, required: true

  defp status_badge(assigns) do
    ~H"""
    <span :if={@count > 0} class="badge badge-soft badge-success badge-xs">Ready</span>
    <span :if={@count == 0} class="badge badge-soft badge-warning badge-xs">Importing</span>
    """
  end

  # ── Step 4: Verify events flowing ─────────────────────────────────────────

  attr :state, State, required: true
  attr :raw_event_count, :integer, required: true

  def verify_events_step(assigns) do
    ~H"""
    <div class="space-y-3 text-sm leading-relaxed text-base-content/80">
      <h2 class="text-lg font-semibold text-base-content">Verify events are flowing</h2>

      <p>
        Launch MTGA (or bring it to the foreground if it's already open)
        and navigate to any screen — the home page, deck builder, or an event
        entry. As MTGA writes to <code>Player.log</code>, Scry 2 will read it
        in real time.
      </p>

      <div :if={@raw_event_count > 0} class="alert alert-soft alert-success text-sm">
        <.icon name="hero-check-circle" class="size-4" />
        <div>
          <p class="font-semibold">Events are flowing</p>
          <p class="text-xs mt-1">
            {@raw_event_count} raw events recorded so far. You're all set.
          </p>
        </div>
      </div>

      <div :if={@raw_event_count == 0} class="alert alert-soft alert-info text-sm">
        <.icon name="hero-arrow-path" class="size-4 animate-spin" />
        <div>
          <p class="font-semibold">Waiting for your first event</p>
          <p class="text-xs mt-1">
            This will update automatically as soon as MTGA writes to the log.
            If nothing appears after a couple of minutes, double-check that
            <em>Detailed Logs (Plugin Support)</em>
            is enabled in MTGA.
          </p>
        </div>
      </div>

      <p class="text-xs text-base-content/60">
        You can continue even if events aren't flowing yet — the health screen
        will keep you informed.
      </p>
    </div>
    """
  end

  # ── Step 5: Done ──────────────────────────────────────────────────────────

  attr :state, State, required: true
  attr :raw_event_count, :integer, required: true
  attr :synthesized_count, :integer, required: true

  def done_step(assigns) do
    ~H"""
    <div class="space-y-3 text-sm leading-relaxed text-base-content/80">
      <h2 class="text-lg font-semibold text-base-content">You're set up</h2>

      <p>
        Scry 2 is now running. From here on, the dashboard at <code>/</code>
        shows a live <strong>health screen</strong>
        — green means everything is working, red or yellow means something
        needs your attention.
      </p>

      <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
        <.summary_row
          label="Player.log located"
          value={@state.detected_path || "(manual path pending)"}
          ok={not is_nil(@state.detected_path)}
        />
        <.summary_row
          label="Events seen"
          value={"#{@raw_event_count} raw events"}
          ok={@raw_event_count > 0}
        />
        <.summary_row
          label="Card data"
          value={"#{@synthesized_count} cards synthesised"}
          ok={@synthesized_count > 0}
        />
      </div>

      <p class="text-xs text-base-content/60">
        Clicking the button below will mark this tour as complete. You can
        always re-run it from the health screen if you want to revisit the
        explanations.
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :ok, :boolean, required: true

  defp summary_row(assigns) do
    ~H"""
    <div class="flex items-start gap-2 rounded bg-base-300/40 px-3 py-2">
      <.icon
        name={if @ok, do: "hero-check-circle", else: "hero-clock"}
        class={"size-4 shrink-0 mt-0.5 #{if @ok, do: "text-success", else: "text-warning"}"}
      />
      <div class="flex-1 min-w-0">
        <p class="text-xs font-medium text-base-content">{@label}</p>
        <p class="text-xs text-base-content/60 break-all">{@value}</p>
      </div>
    </div>
    """
  end
end
