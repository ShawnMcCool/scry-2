defmodule Scry2Web.EventExplorer do
  @moduledoc """
  LiveComponent shell for the event explorer — owns filter state, runs
  queries via `Events.list_events/1`, and composes function components
  from `EventComponents`.

  Embeddable in any LiveView with preset filters:

      <.live_component
        module={EventExplorer}
        id="match-events"
        preset={%{match_id: @match.mtga_match_id}}
        player_id={@active_player_id}
      />

  The host LiveView must forward PubSub refreshes:

      send_update(EventExplorer, id: "match-events", refresh: true)
  """
  use Scry2Web, :live_component

  alias Scry2.Events

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       events: [],
       total_count: 0,
       page: 1,
       per_page: 50,
       filter_values: %{},
       event_types: known_type_slugs()
     )}
  end

  @impl true
  def update(%{refresh: true}, socket) do
    {:ok, fetch_events(socket)}
  end

  def update(assigns, socket) do
    preset = Map.get(assigns, :preset, %{})
    player_id = Map.get(assigns, :player_id)

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:preset, preset)
      |> assign(:player_id, player_id)
      |> merge_preset_into_filters(preset)
      |> fetch_events()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter_values =
      socket.assigns.filter_values
      |> Map.merge(coerce_filter_params(params))

    socket =
      socket
      |> assign(:filter_values, filter_values)
      |> assign(:page, 1)
      |> fetch_events()

    {:noreply, socket}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> fetch_events()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Scry2Web.EventComponents.event_filters
        filter_values={@filter_values}
        event_types={@event_types}
        enabled_filters={enabled_filters(@preset)}
      />
      <Scry2Web.EventComponents.event_list
        events={@events}
        total_count={@total_count}
        page={@page}
        per_page={@per_page}
      />
    </div>
    """
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp fetch_events(socket) do
    opts = build_query_opts(socket.assigns)

    {events, total_count} = Events.list_events(opts)

    assign(socket,
      events: events,
      total_count: total_count
    )
  end

  defp build_query_opts(assigns) do
    filters = assigns.filter_values
    page = assigns.page
    per_page = assigns.per_page

    opts = [
      limit: per_page,
      offset: (page - 1) * per_page
    ]

    opts
    |> maybe_add(:event_types, filter_to_list(filters[:event_type]))
    |> maybe_add(:since, parse_date(filters[:since]))
    |> maybe_add(:until, parse_date_end(filters[:until]))
    |> maybe_add(:text_search, non_empty(filters[:text_search]))
    |> maybe_add(:match_id, non_empty(filters[:match_id]))
    |> maybe_add(:draft_id, non_empty(filters[:draft_id]))
    |> maybe_add(:session_id, non_empty(filters[:session_id]))
    |> maybe_add(:player_id, assigns.player_id)
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_to_list(nil), do: nil
  defp filter_to_list(""), do: nil
  defp filter_to_list(type) when is_binary(type), do: [type]

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_date_end(nil), do: nil
  defp parse_date_end(""), do: nil

  defp parse_date_end(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
      _ -> nil
    end
  end

  defp coerce_filter_params(params) do
    %{
      event_type: params["event_type"],
      since: params["since"],
      until: params["until"],
      text_search: params["text_search"],
      match_id: params["match_id"],
      draft_id: params["draft_id"],
      session_id: params["session_id"]
    }
  end

  defp merge_preset_into_filters(socket, preset) do
    merged = Map.merge(socket.assigns.filter_values, preset)
    assign(socket, :filter_values, merged)
  end

  defp enabled_filters(preset) do
    base = [:type, :time, :text, :match, :draft, :session]
    # Hide filters that are locked by preset
    preset_keys = Map.keys(preset || %{})

    key_to_filter = %{
      match_id: :match,
      draft_id: :draft,
      session_id: :session
    }

    locked = Enum.map(preset_keys, &Map.get(key_to_filter, &1)) |> Enum.reject(&is_nil/1)
    base -- locked
  end

  defp known_type_slugs do
    Events.count_by_type() |> Map.keys() |> Enum.sort()
  end
end
