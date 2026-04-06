defmodule Scry2Web.ConsoleLive do
  @moduledoc """
  Sticky dropdown console — always mounted via `Scry2Web.Layouts.console_mount/1`
  from the root layout. Receives log entries via PubSub and renders them into
  a LiveView stream with filtering, pause, clear, resize, download, and copy
  actions.

  ## Lifecycle notes

  * `mount/3` only subscribes and reads the `Scry2.Console.RecentEntries` snapshot
    (in-memory GenServer — no database query). `connected?/1` gate keeps the
    first HTTP mount cheap.
  * State-persisting actions (filter, buffer-size) flow through `Scry2.Console`
    → `RecentEntries`, which debounces persistence to `Scry2.Settings` over 2s.
  * The `@open` flag lives on the server so morphdom never reverts drawer
    state on LiveView re-renders.
  """
  use Scry2Web, :live_view

  alias Scry2.Console
  alias Scry2.Console.{RecentEntries, Filter, DisplayHelpers}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Console.subscribe()
    end

    snapshot =
      if connected?(socket) do
        Console.snapshot()
      else
        %{entries: [], cap: 2_000, filter: Filter.new_with_defaults()}
      end

    socket =
      socket
      |> assign(:filter, snapshot.filter)
      |> assign(:paused, false)
      |> assign(:buffer_size, snapshot.cap)
      |> assign(:open, false)
      |> assign(:app_components, DisplayHelpers.app_components())
      |> assign(:framework_components, DisplayHelpers.framework_components())
      # Stream limit is pinned at the buffer's max_cap and never reconfigured.
      # Phoenix LiveView forbids stream_configure/3 after a stream has been
      # populated, so a dynamic limit would crash on resize. The buffer itself
      # caps entries at the user-chosen size; the stream just mirrors whatever
      # the buffer delivers.
      |> stream_configure(:entries,
        dom_id: &entry_dom_id/1,
        limit: -RecentEntries.max_cap()
      )
      |> stream(:entries, Enum.reverse(snapshot.entries))

    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="console-sticky-root"
      class="console-overlay"
      data-state={if @open, do: "open", else: "closed"}
      phx-hook="Console"
    >
      <div class="console-panel" data-captures-keys={@open && "true"}>
        <Scry2Web.ConsoleComponents.chip_row
          filter={@filter}
          app_components={@app_components}
          framework_components={@framework_components}
        />
        <Scry2Web.ConsoleComponents.log_list streams={@streams} />
        <Scry2Web.ConsoleComponents.action_footer
          paused={@paused}
          buffer_size={@buffer_size}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_info({:log_entry, entry}, socket) do
    cond do
      socket.assigns.paused ->
        {:noreply, socket}

      Filter.matches?(entry, socket.assigns.filter) ->
        {:noreply, stream_insert(socket, :entries, entry, at: 0)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:buffer_cleared, socket) do
    {:noreply, stream(socket, :entries, [], reset: true)}
  end

  def handle_info({:buffer_resized, new_cap}, socket) do
    # Phoenix LiveView does NOT allow stream_configure/3 after the stream
    # has been populated (raises ArgumentError). The stream limit was fixed
    # at RecentEntries.max_cap() in mount; the Buffer itself enforces the user's
    # chosen cap. On resize we just reset the stream contents to match the
    # newly-truncated buffer.
    snapshot = Console.snapshot()

    socket =
      socket
      |> assign(:buffer_size, new_cap)
      |> stream(:entries, Enum.reverse(snapshot.entries), reset: true)

    {:noreply, socket}
  end

  def handle_info({:filter_changed, filter}, socket) do
    current_filter = socket.assigns.filter

    if DisplayHelpers.only_search_changed?(current_filter, filter) do
      # Text search is handled by the client-side hook via data-message
      # attributes — no server-side re-stream needed. Just update the
      # assign so cross-tab sync works without the cursor jump that a
      # re-stream would cause.
      {:noreply, assign(socket, :filter, filter)}
    else
      snapshot = Console.snapshot()
      visible = Enum.filter(snapshot.entries, &Filter.matches?(&1, filter))

      socket =
        socket
        |> assign(:filter, filter)
        |> stream(:entries, Enum.reverse(visible), reset: true)

      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_console", _params, socket) do
    # Open/close state lives on the server so morphdom never reverts it on
    # LiveView re-renders. The JS hook pushes this event on backtick, Escape,
    # and backdrop click.
    {:noreply, assign(socket, :open, not socket.assigns.open)}
  end

  def handle_event("toggle_component", %{"component" => component_string}, socket) do
    component = safe_to_existing_atom(component_string)
    new_filter = Filter.toggle_component(socket.assigns.filter, component)
    :ok = Console.update_filter(new_filter)
    {:noreply, socket}
  end

  def handle_event("solo_component", %{"component" => component_string}, socket) do
    component = safe_to_existing_atom(component_string)
    new_filter = Filter.solo_component(socket.assigns.filter, component)
    :ok = Console.update_filter(new_filter)
    {:noreply, socket}
  end

  def handle_event("mute_component", %{"component" => component_string}, socket) do
    component = safe_to_existing_atom(component_string)
    new_filter = Filter.mute_component(socket.assigns.filter, component)
    :ok = Console.update_filter(new_filter)
    {:noreply, socket}
  end

  def handle_event("set_level", %{"level" => level_string}, socket) do
    level = safe_to_existing_atom(level_string)
    new_filter = %{socket.assigns.filter | level: level}
    :ok = Console.update_filter(new_filter)
    {:noreply, socket}
  end

  def handle_event("search", %{"value" => query}, socket) do
    new_filter = %{socket.assigns.filter | search: query}
    :ok = Console.update_filter(new_filter)
    {:noreply, assign(socket, :filter, new_filter)}
  end

  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, not socket.assigns.paused)}
  end

  def handle_event("clear_buffer", _params, socket) do
    :ok = Console.clear()
    {:noreply, socket}
  end

  def handle_event("resize_buffer", %{"size" => size_string}, socket) do
    case Integer.parse(size_string) do
      {size, _} -> Console.resize(size)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("download_buffer", _params, socket) do
    snapshot = Console.snapshot()
    visible = Enum.filter(snapshot.entries, &Filter.matches?(&1, socket.assigns.filter))
    payload = DisplayHelpers.format_lines(visible)

    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H-%M-%S")
    filename = "scry_2-#{timestamp}.log"

    {:noreply, push_event(socket, "console:download", %{filename: filename, content: payload})}
  end

  def handle_event("copy_visible", _params, socket) do
    snapshot = Console.snapshot()
    visible = Enum.filter(snapshot.entries, &Filter.matches?(&1, socket.assigns.filter))
    payload = DisplayHelpers.format_lines(visible)

    {:noreply, push_event(socket, "console:copy", %{content: payload})}
  end

  # Safely converts a string from a phx-value-* binding or form field to an
  # atom that already exists in the atom table. Returns :system on any failure.
  defp safe_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :system
  end

  # Stable DOM id for a log entry — used by both `mount/3` and the
  # `:buffer_resized` handler to keep the stream-configure function reference
  # consistent.
  defp entry_dom_id(%{id: id}), do: "console-log-#{id}"
end
