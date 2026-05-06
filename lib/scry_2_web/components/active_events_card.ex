defmodule Scry2Web.Components.ActiveEventsCard do
  @moduledoc """
  Lists the player's current MTGA event entries — Premier Draft
  records like `4-1`, Standard ladder progress, Jump-In activity, etc.
  Sourced from `Scry2.MtgaEvents.read_active_events/1` (memory-read
  via Chain 3).

  The card is filtered to actively-engaged entries upstream
  (`current_event_state != 0`); we just render. Empty list → empty
  state.

  Used on `/economy`. All formatting helpers live in
  `Scry2Web.Components.ActiveEventsCard.Helpers` per ADR-013.
  """

  use Phoenix.Component

  alias Scry2Web.Components.ActiveEventsCard.Helpers, as: H

  attr :records, :list,
    required: true,
    doc: "List of %{...} maps from Scry2.MtgaEvents.read_active_events/1."

  attr :error, :any,
    default: nil,
    doc: "Error reason from read_active_events/1, or nil. Drives empty-state copy."

  def active_events_card(assigns) do
    ~H"""
    <section
      class="card bg-base-200 border border-base-300"
      data-role="active-events-card"
    >
      <div class="card-body">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title">Active events</h2>
          <span :if={@records != []} class="text-xs text-base-content/60">
            {length(@records)} {H.entry_word(length(@records))}
          </span>
        </div>

        <%= cond do %>
          <% @records != [] -> %>
            <div class="overflow-x-auto rounded-lg border border-base-content/5 mt-3">
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/40">
                    <th>Event</th>
                    <th>Format</th>
                    <th class="text-right">Record</th>
                    <th class="text-right">State</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={r <- @records} class="hover">
                    <td class="font-medium">{H.display_name(r)}</td>
                    <td class="text-base-content/70">{H.format_label(r)}</td>
                    <td class="text-right tabular-nums">{H.record_label(r)}</td>
                    <td class="text-right">
                      <span class={[
                        "badge badge-sm badge-soft",
                        H.state_badge_class(r)
                      ]}>
                        {H.state_label(r)}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% @error != nil -> %>
            <div class="mt-3 text-sm text-base-content/60">
              {H.error_message(@error)}
            </div>
          <% true -> %>
            <div class="mt-3 text-sm text-base-content/60">
              No active events. Once you're in a queue or on a ladder this
              card will list your standings.
            </div>
        <% end %>
      </div>
    </section>
    """
  end
end
