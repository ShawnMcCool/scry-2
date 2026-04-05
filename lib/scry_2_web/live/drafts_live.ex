defmodule Scry2Web.DraftsLive do
  use Scry2Web, :live_view

  alias Scry2.Drafts
  alias Scry2.Topics
  alias Scry2Web.MatchesHelpers, as: Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.drafts_updates())

    {:ok, assign(socket, drafts: [], draft: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    draft = Drafts.get_draft_with_picks(String.to_integer(id))
    {:noreply, assign(socket, draft: draft, drafts: [])}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, drafts: Drafts.list_drafts(limit: 100), draft: nil)}
  end

  @impl true
  def handle_info({:draft_updated, _}, socket) do
    {:noreply, assign(socket, drafts: Drafts.list_drafts(limit: 100))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{draft: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold">Drafts</h1>

      <p :if={@drafts == []} class="text-base-content/60">
        No drafts recorded yet.
      </p>

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
                  {Helpers.format_started_at(draft.started_at)}
                </.link>
              </td>
              <td>{draft.set_code || "—"}</td>
              <td>{Helpers.format_label(draft.format)}</td>
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
    <Layouts.app flash={@flash}>
      <.link navigate={~p"/drafts"} class="link text-sm">&larr; All drafts</.link>

      <h1 class="text-2xl font-semibold">{@draft.event_name}</h1>
      <p class="text-sm text-base-content/60">
        {@draft.set_code} · {Helpers.format_label(@draft.format)} · {Helpers.format_started_at(
          @draft.started_at
        )}
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
