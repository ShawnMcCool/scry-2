defmodule Scry2Web.ConsolePageLive do
  @moduledoc """
  Full-page `/console` route. Same data and events as the sticky drawer,
  different layout: full viewport instead of a half-height dropdown.

  Shares filter/buffer state with `Scry2Web.ConsoleLive` via
  `Scry2.Console.RecentEntries` (single source of truth in the supervision tree).
  PubSub keeps both in sync.
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
      |> assign(:app_components, DisplayHelpers.app_components())
      |> assign(:framework_components, DisplayHelpers.framework_components())
      # See ConsoleLive.mount/3 — stream limit is pinned at max_cap and
      # never reconfigured. Phoenix LV forbids stream_configure after the
      # stream is populated.
      |> stream_configure(:entries,
        dom_id: &entry_dom_id/1,
        limit: -RecentEntries.max_cap()
      )
      |> stream(:entries, Enum.reverse(snapshot.entries))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="console-fullpage-wrap" id="console-page">
        <Scry2Web.ConsoleComponents.chip_row
          filter={@filter}
          app_components={@app_components}
          framework_components={@framework_components}
        />
        <Scry2Web.ConsoleComponents.log_list streams={@streams} />
        <Scry2Web.ConsoleComponents.action_footer
          paused={@paused}
          buffer_size={@buffer_size}
          show_fullpage_link={false}
        />
      </div>
    </Layouts.app>
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

  defp safe_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :system
  end

  defp entry_dom_id(%{id: id}), do: "console-log-#{id}"
end
