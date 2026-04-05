defmodule Scry2Web.ConsoleComponents do
  @moduledoc """
  Shared HEEx function components used by both `Scry2Web.ConsoleLive`
  (sticky drawer) and `Scry2Web.ConsolePageLive` (full-page `/console` route).

  Pure render functions driven entirely by assigns — no state, no PubSub.
  """
  use Scry2Web, :html

  alias Scry2.Console.View

  @doc """
  Header row with component chips, level filter, and search input.

  ## Attributes

    * `:filter` — the current `%Scry2.Console.Filter{}` struct
    * `:app_components` — list of app component atoms
    * `:framework_components` — list of framework component atoms
  """
  attr :filter, :any, required: true
  attr :app_components, :list, required: true
  attr :framework_components, :list, required: true

  def chip_row(assigns) do
    ~H"""
    <header class="console-header">
      <div class="console-chips">
        <span class="console-chip-group-label">app</span>
        <button
          :for={component <- @app_components}
          type="button"
          class={[
            "badge badge-sm console-chip",
            View.component_badge_class(component),
            View.chip_state_class(@filter, component)
          ]}
          phx-click="toggle_component"
          phx-value-component={component}
          title={"click to toggle #{component}"}
        >
          {View.component_label(component)}
        </button>

        <span class="console-chip-divider" aria-hidden="true"></span>
        <span class="console-chip-group-label">framework</span>

        <button
          :for={component <- @framework_components}
          type="button"
          class={[
            "badge badge-sm console-chip",
            View.component_badge_class(component),
            View.chip_state_class(@filter, component)
          ]}
          phx-click="toggle_component"
          phx-value-component={component}
          title={"click to toggle #{component}"}
        >
          {View.component_label(component)}
        </button>
      </div>

      <%!-- Level floor. :debug is included because Ecto query logs and
            Phoenix/LiveView request logs are emitted at :debug level —
            flipping a framework component chip has no visible effect
            unless the floor is also dropped to :debug. --%>
      <div class="console-level-filter join">
        <button
          :for={level <- [:debug, :info, :warning, :error]}
          type="button"
          class={["join-item btn btn-xs", View.level_button_class(@filter, level)]}
          phx-click="set_level"
          phx-value-level={level}
        >
          {level}
        </button>
      </div>

      <input
        id="console-search-input"
        type="text"
        class="input input-sm input-bordered console-search"
        placeholder="search..."
        value={@filter.search}
        phx-keyup="search"
        phx-debounce="200"
        name="search-query"
        data-console-search
      />
    </header>
    """
  end

  @doc """
  Log entry list — iterates the entries stream and renders each entry.

  ## Attributes

    * `:streams` — the socket streams map; must contain `:entries`
  """
  attr :streams, :any, required: true

  def log_list(assigns) do
    ~H"""
    <main class="console-log" id="console-entries" phx-update="stream">
      <div
        :for={{dom_id, entry} <- @streams.entries}
        id={dom_id}
        class={["console-entry", View.level_color(entry.level)]}
        data-level={entry.level}
        data-component={entry.component}
        data-message={View.entry_search_text(entry)}
      >
        <span class="console-timestamp">{View.format_timestamp(entry.timestamp)}</span>
        <span class={[
          "badge badge-xs console-component-badge",
          View.component_badge_class(entry.component)
        ]}>
          {View.component_label(entry.component)}
        </span>
        <span class="console-message">{entry.message}</span>
      </div>
    </main>
    """
  end

  @doc """
  Footer with buffer management actions and size slider.

  When `show_fullpage_link` is true (the default), renders a navigation link
  to the full-page `/console` route. Pass `false` from `ConsolePageLive`
  since it IS the full page.

  ## Attributes

    * `:paused` — whether log streaming is paused
    * `:buffer_size` — current buffer capacity
    * `:show_fullpage_link` — whether to render the "full page" link (default: `true`)
  """
  attr :paused, :boolean, required: true
  attr :buffer_size, :integer, required: true
  attr :show_fullpage_link, :boolean, default: true

  def action_footer(assigns) do
    ~H"""
    <footer class="console-footer">
      <button type="button" class="btn btn-xs" phx-click="toggle_pause">
        {View.pause_button_label(@paused)}
      </button>
      <button type="button" class="btn btn-xs" phx-click="clear_buffer">clear</button>
      <button type="button" class="btn btn-xs" phx-click="copy_visible">copy</button>
      <button type="button" class="btn btn-xs" phx-click="download_buffer">download</button>
      <.link :if={@show_fullpage_link} navigate={~p"/console"} class="btn btn-xs">
        full page
      </.link>
      <div class="console-buffer-size">
        <form phx-change="resize_buffer">
          <input
            type="range"
            name="size"
            min="100"
            max="50000"
            step="100"
            value={@buffer_size}
            class="range range-xs"
          />
        </form>
        <span class="console-buffer-size-label text-xs">{@buffer_size}</span>
      </div>
    </footer>
    """
  end
end
