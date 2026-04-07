defmodule Scry2Web.EventsLive do
  @moduledoc """
  LiveView for browsing and inspecting domain events.

  - `/events` — full event explorer with search, filters, and correlation
  - `/events/:id` — detail view for a single event
  """
  use Scry2Web, :live_view

  alias Scry2.Events
  alias Scry2.Events.Event
  alias Scry2.Topics
  alias Scry2Web.EventsHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.domain_events())

    {:ok, assign(socket, event: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Events.get(String.to_integer(id)) do
      {:ok, event} ->
        event = Map.put(event, :id, String.to_integer(id))
        {:noreply, assign(socket, event: event)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: ~p"/events")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, event: nil)}
  end

  @impl true
  def handle_info({:domain_event, _id, _type}, socket) do
    if socket.assigns.event do
      # On detail view, no refresh needed
      {:noreply, socket}
    else
      send_update(Scry2Web.EventExplorer, id: "events-explorer", refresh: true)
      {:noreply, socket}
    end
  end

  def handle_info(:reload_data, socket) do
    {:noreply, assign(socket, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── List view ───────────────────────────────────────────────────────

  @impl true
  def render(%{event: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-4">Events</h1>

      <.live_component
        module={Scry2Web.EventExplorer}
        id="events-explorer"
        player_id={@active_player_id}
      />
    </Layouts.app>
    """
  end

  # ── Detail view ─────────────────────────────────────────────────────

  def render(%{event: event} = assigns) when not is_nil(event) do
    assigns =
      assign(assigns,
        type_slug: Event.type_slug(event),
        category: EventsHelpers.event_category(event),
        summary: EventsHelpers.event_summary(event),
        correlation: EventsHelpers.correlation_label(event),
        payload_fields: event_payload_fields(event)
      )

    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <.back_link navigate={~p"/events"} label="All events" />

      <div class="flex items-center gap-3 mb-4">
        <h1 class="text-2xl font-semibold">{@type_slug}</h1>
        <span class={[
          "badge",
          EventsHelpers.type_badge_color(@category)
        ]}>
          {@category}
        </span>
      </div>

      <p class="text-base-content/60 mb-6">{@summary}</p>

      <%!-- Correlation links --%>
      <section :if={has_correlations?(@event)} class="mb-6">
        <h2 class="text-sm font-semibold text-base-content/50 mb-2 uppercase tracking-wider">
          Related Events
        </h2>
        <div class="flex flex-wrap gap-2">
          <.link
            :if={match_id = Map.get(@event, :mtga_match_id)}
            navigate={~p"/events?match_id=#{match_id}"}
            class="btn btn-xs btn-soft"
          >
            All match events
          </.link>
          <.link
            :if={draft_id = Map.get(@event, :mtga_draft_id)}
            navigate={~p"/events?draft_id=#{draft_id}"}
            class="btn btn-xs btn-soft"
          >
            All draft events
          </.link>
        </div>
      </section>

      <%!-- Event fields --%>
      <section class="mb-6">
        <h2 class="text-sm font-semibold text-base-content/50 mb-2 uppercase tracking-wider">
          Fields
        </h2>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <tbody>
              <tr :for={{key, value} <- @payload_fields}>
                <td class="font-mono text-xs text-base-content/50 w-48">{key}</td>
                <td class="font-mono text-xs break-all">{format_field_value(value)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <%!-- Metadata --%>
      <section>
        <h2 class="text-sm font-semibold text-base-content/50 mb-2 uppercase tracking-wider">
          Metadata
        </h2>
        <div class="text-xs text-base-content/40 space-y-1">
          <p>Event ID: {@event.id}</p>
          <p>Player ID: {@event.player_id || "—"}</p>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp event_payload_fields(event) do
    event
    |> Map.from_struct()
    |> Map.drop([:__struct__, :id, :player_id])
    |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
  end

  defp format_field_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_field_value(value) when is_list(value), do: inspect(value, limit: 20, pretty: true)
  defp format_field_value(value) when is_map(value), do: inspect(value, limit: 20, pretty: true)
  defp format_field_value(nil), do: "—"
  defp format_field_value(value), do: to_string(value)

  defp has_correlations?(event) do
    Map.get(event, :mtga_match_id) != nil or Map.get(event, :mtga_draft_id) != nil
  end
end
