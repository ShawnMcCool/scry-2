defmodule Scry2Web.DraftsLive do
  use Scry2Web, :live_view

  alias Scry2.Drafts
  alias Scry2.Topics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.drafts_updates())

    {:ok, assign(socket, drafts: [], draft: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    draft = Drafts.get_draft_with_picks(String.to_integer(id))
    {:noreply, assign(socket, draft: draft, drafts: [])}
  end

  def handle_params(_params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]

    {:noreply,
     assign(socket, drafts: Drafts.list_drafts(limit: 100, player_id: player_id), draft: nil)}
  end

  @impl true
  def handle_info({:draft_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]

    {:noreply,
     assign(socket,
       drafts: Drafts.list_drafts(limit: 100, player_id: player_id),
       reload_timer: nil
     )}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{draft: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold">Drafts</h1>

      <.empty_state :if={@drafts == []}>
        No drafts recorded yet.
      </.empty_state>

      <div :if={@drafts != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Started</th>
              <th>Set</th>
              <th>Format</th>
              <th>W-L</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={draft <- @drafts} class="hover">
              <td>
                <.link navigate={~p"/drafts/#{draft.id}"} class="link">
                  {format_datetime(draft.started_at)}
                </.link>
              </td>
              <td>{draft.set_code || "—"}</td>
              <td>{format_label(draft.format)}</td>
              <td class="tabular-nums">
                {draft.wins || 0}-{draft.losses || 0}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  def render(%{draft: _} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <.back_link navigate={~p"/drafts"} label="All drafts" />

      <h1 class="text-2xl font-semibold">{@draft.event_name}</h1>
      <p class="text-sm text-base-content/60">
        {@draft.set_code} · {format_label(@draft.format)} · {format_datetime(@draft.started_at)}
      </p>

      <section>
        <h2 class="text-lg font-semibold mb-2">Picks ({length(@draft.picks)})</h2>
        <table :if={@draft.picks != []} class="table table-sm">
          <thead>
            <tr>
              <th>Pack</th>
              <th>Pick</th>
              <th>Arena ID</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={pick <- @draft.picks}>
              <td>{pick.pack_number}</td>
              <td>{pick.pick_number}</td>
              <td class="tabular-nums">{pick.picked_arena_id}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
