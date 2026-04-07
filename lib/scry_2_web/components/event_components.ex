defmodule Scry2Web.EventComponents do
  @moduledoc """
  Shared function components for domain event display — type badges,
  event rows, event lists with pagination, and filter bars.

  Pure render functions driven entirely by assigns — no state, no PubSub.
  Used by `EventExplorer` LiveComponent and embeddable in any page.
  """
  use Scry2Web, :html

  alias Scry2.Events.Event
  alias Scry2Web.EventsHelpers
  alias Scry2Web.LiveHelpers

  @doc """
  Renders a colored badge for an event type slug.

  ## Examples

      <.type_badge event={@event} />
  """
  attr :event, :any, required: true

  def type_badge(assigns) do
    category = EventsHelpers.event_category(assigns.event)
    badge_color = EventsHelpers.type_badge_color(category)
    slug = Event.type_slug(assigns.event)
    assigns = assign(assigns, badge_color: badge_color, slug: slug)

    ~H"""
    <span class={["badge badge-sm font-mono", @badge_color]}>{@slug}</span>
    """
  end

  @doc """
  Renders a single event row with type badge, timestamp, correlation, and summary.

  ## Examples

      <.event_row event={@event} />
  """
  attr :event, :any, required: true

  def event_row(assigns) do
    assigns =
      assign(assigns,
        summary: EventsHelpers.event_summary(assigns.event),
        correlation: EventsHelpers.correlation_label(assigns.event),
        timestamp: LiveHelpers.format_datetime(Map.get(assigns.event, :occurred_at))
      )

    ~H"""
    <td class="text-base-content/50 tabular-nums whitespace-nowrap">{@timestamp}</td>
    <td><.type_badge event={@event} /></td>
    <td class="text-xs text-accent/70 font-mono">{@correlation}</td>
    <td class="text-base-content/70 truncate max-w-xs">{@summary}</td>
    """
  end

  @doc """
  Renders a table of events with pagination controls.

  ## Examples

      <.event_list events={@events} total_count={@total_count} page={@page} per_page={@per_page} />
  """
  attr :events, :list, required: true
  attr :total_count, :integer, required: true
  attr :page, :integer, default: 1
  attr :per_page, :integer, default: 50
  attr :on_page_change, :string, default: "page"

  def event_list(assigns) do
    total_pages = max(1, ceil(assigns.total_count / assigns.per_page))
    assigns = assign(assigns, total_pages: total_pages)

    ~H"""
    <div>
      <div class="flex justify-between items-center mb-2 text-xs text-base-content/50">
        <span>
          Showing {min((@page - 1) * @per_page + 1, @total_count)}–{min(
            @page * @per_page,
            @total_count
          )} of {@total_count} events
        </span>
        <div :if={@total_pages > 1} class="flex items-center gap-2">
          <span>Page {@page} of {@total_pages}</span>
          <button
            :if={@page > 1}
            phx-click={@on_page_change}
            phx-value-page={@page - 1}
            class="btn btn-xs btn-ghost"
          >
            ◀
          </button>
          <button
            :if={@page < @total_pages}
            phx-click={@on_page_change}
            phx-value-page={@page + 1}
            class="btn btn-xs btn-ghost"
          >
            ▶
          </button>
        </div>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-sm table-zebra">
          <thead>
            <tr class="text-xs text-base-content/50">
              <th>Time</th>
              <th>Type</th>
              <th>Correlation</th>
              <th>Summary</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <.link
              :for={event <- @events}
              navigate={~p"/events/#{event.id}"}
              class="hover:bg-base-200/50 cursor-pointer contents"
            >
              <tr>
                <.event_row event={event} />
                <td class="text-right text-base-content/40">→</td>
              </tr>
            </.link>
          </tbody>
        </table>
      </div>

      <.empty_state :if={@events == []} icon="hero-inbox">
        No events match the current filters.
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the filter bar for event search.

  ## Examples

      <.event_filters
        filter_values={@filter_values}
        event_types={@event_types}
        enabled_filters={[:type, :time, :text, :match, :draft, :session]}
      />
  """
  attr :filter_values, :map, required: true
  attr :event_types, :list, default: []
  attr :enabled_filters, :list, default: [:type, :time, :text, :match, :draft, :session]

  def event_filters(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-3 mb-4">
      <div class="text-xs text-base-content/40 mb-2 uppercase tracking-wider">Filters</div>
      <.form for={%{}} phx-change="filter" class="flex flex-col gap-2">
        <div class="flex flex-wrap gap-2 items-center">
          <select
            :if={:type in @enabled_filters}
            name="event_type"
            class="select select-bordered select-sm"
            value={@filter_values[:event_type] || ""}
          >
            <option value="">All types</option>
            <option
              :for={type <- @event_types}
              value={type}
              selected={@filter_values[:event_type] == type}
            >
              {type}
            </option>
          </select>

          <input
            :if={:time in @enabled_filters}
            type="date"
            name="since"
            value={@filter_values[:since] || ""}
            placeholder="Since"
            class="input input-bordered input-sm"
          />

          <input
            :if={:time in @enabled_filters}
            type="date"
            name="until"
            value={@filter_values[:until] || ""}
            placeholder="Until"
            class="input input-bordered input-sm"
          />

          <input
            :if={:text in @enabled_filters}
            type="text"
            name="text_search"
            value={@filter_values[:text_search] || ""}
            placeholder="Search payloads…"
            phx-debounce="300"
            class="input input-bordered input-sm flex-1 min-w-48"
          />
        </div>

        <div
          :if={Enum.any?([:match, :draft, :session], &(&1 in @enabled_filters))}
          class="flex flex-wrap gap-2"
        >
          <input
            :if={:match in @enabled_filters}
            type="text"
            name="match_id"
            value={@filter_values[:match_id] || ""}
            placeholder="Match ID"
            phx-debounce="300"
            class="input input-bordered input-xs font-mono"
          />

          <input
            :if={:draft in @enabled_filters}
            type="text"
            name="draft_id"
            value={@filter_values[:draft_id] || ""}
            placeholder="Draft ID"
            phx-debounce="300"
            class="input input-bordered input-xs font-mono"
          />

          <input
            :if={:session in @enabled_filters}
            type="text"
            name="session_id"
            value={@filter_values[:session_id] || ""}
            placeholder="Session ID"
            phx-debounce="300"
            class="input input-bordered input-xs font-mono"
          />
        </div>
      </.form>
    </div>
    """
  end
end
