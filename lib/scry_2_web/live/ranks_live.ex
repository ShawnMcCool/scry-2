defmodule Scry2Web.RanksLive do
  @moduledoc """
  LiveView for rank progression display.

  Shows the player's current rank state and a history table of all
  rank snapshots over time. Subscribes to `ranks:updates` for live
  updates when new snapshots are projected.
  """
  use Scry2Web, :live_view

  alias Scry2.Ranks
  alias Scry2.Topics
  alias Scry2Web.RanksHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.ranks_updates())

    {:ok, assign(socket, snapshots: [], latest: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]
    snapshots = Ranks.list_snapshots(player_id: player_id)
    latest = List.last(snapshots)

    {:noreply, assign(socket, snapshots: snapshots, latest: latest)}
  end

  @impl true
  def handle_info({:rank_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    snapshots = Ranks.list_snapshots(player_id: player_id)
    latest = List.last(snapshots)

    {:noreply, assign(socket, snapshots: snapshots, latest: latest, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-6">Rank Progression</h1>

      <.empty_state :if={is_nil(@latest)}>
        No rank data yet. Rank snapshots are captured after each ranked match.
      </.empty_state>

      <div :if={@latest} class="space-y-8">
        <%!-- Current rank cards --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <.rank_card
            title="Constructed"
            class={@latest.constructed_class}
            level={@latest.constructed_level}
            step={@latest.constructed_step}
            won={@latest.constructed_matches_won}
            lost={@latest.constructed_matches_lost}
            format_type="Constructed"
          />
          <.rank_card
            title="Limited"
            class={@latest.limited_class}
            level={@latest.limited_level}
            step={@latest.limited_step}
            won={@latest.limited_matches_won}
            lost={@latest.limited_matches_lost}
            format_type="Limited"
          />
        </div>

        <%!-- History table --%>
        <section>
          <h2 class="text-lg font-semibold mb-3">History</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Constructed</th>
                  <th>Record</th>
                  <th>Limited</th>
                  <th>Record</th>
                  <th>Season</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={snapshot <- Enum.reverse(@snapshots)}>
                  <td class="tabular-nums">{format_datetime(snapshot.occurred_at)}</td>
                  <td>
                    <div class="flex items-center gap-2">
                      <.rank_icon
                        :if={snapshot.constructed_class}
                        rank={snapshot.constructed_class}
                        format_type="Constructed"
                        class="h-5"
                      />
                      {RanksHelpers.format_rank(
                        snapshot.constructed_class,
                        snapshot.constructed_level
                      )}
                    </div>
                  </td>
                  <td class="tabular-nums">
                    {RanksHelpers.format_record(
                      snapshot.constructed_matches_won,
                      snapshot.constructed_matches_lost
                    )}
                  </td>
                  <td>
                    <div class="flex items-center gap-2">
                      <.rank_icon
                        :if={snapshot.limited_class}
                        rank={snapshot.limited_class}
                        format_type="Limited"
                        class="h-5"
                      />
                      {RanksHelpers.format_rank(snapshot.limited_class, snapshot.limited_level)}
                    </div>
                  </td>
                  <td class="tabular-nums">
                    {RanksHelpers.format_record(
                      snapshot.limited_matches_won,
                      snapshot.limited_matches_lost
                    )}
                  </td>
                  <td class="tabular-nums">{snapshot.season_ordinal || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # ── Private components ──────────────────────────────────────────────

  attr :title, :string, required: true
  attr :class, :string, default: nil
  attr :level, :integer, default: nil
  attr :step, :integer, default: nil
  attr :won, :integer, default: nil
  attr :lost, :integer, default: nil
  attr :format_type, :string, required: true

  defp rank_card(assigns) do
    {filled, total} = RanksHelpers.step_pips(assigns.step)
    assigns = assign(assigns, filled: filled, total: total)

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-5">
        <p class="text-xs uppercase text-base-content/60">{@title}</p>
        <div class="flex items-center gap-3 mt-1">
          <.rank_icon :if={@class} rank={@class} format_type={@format_type} class="h-10" />
          <div>
            <p class="text-xl font-semibold">
              {RanksHelpers.format_rank(@class, @level)}
            </p>
            <div class="flex gap-1 mt-1">
              <div
                :for={i <- 1..@total}
                class={[
                  "w-2 h-2 rounded-full",
                  if(i <= @filled, do: "bg-primary", else: "bg-base-content/20")
                ]}
              />
            </div>
          </div>
        </div>
        <p class="text-sm text-base-content/60 mt-2">
          {RanksHelpers.format_record(@won, @lost)}
        </p>
      </div>
    </div>
    """
  end
end
