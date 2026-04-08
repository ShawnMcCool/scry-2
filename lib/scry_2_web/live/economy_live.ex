defmodule Scry2Web.EconomyLive do
  @moduledoc """
  LiveView for economy tracking — event ROI, inventory balances,
  and resource transactions.
  """
  use Scry2Web, :live_view

  alias Scry2.Economy
  alias Scry2.Topics
  alias Scry2Web.EconomyHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.economy_updates())

    {:ok, assign(socket, entries: [], inventory: nil, transactions: [], reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:economy_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    {:noreply, load_data(socket) |> assign(:reload_timer, nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    player_id = socket.assigns[:active_player_id]

    assign(socket,
      entries: Economy.list_event_entries(player_id: player_id),
      inventory: Economy.latest_inventory(player_id: player_id),
      transactions: Economy.list_transactions(player_id: player_id, limit: 50)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-6">Economy</h1>

      <.empty_state :if={is_nil(@inventory) and @entries == [] and @transactions == []}>
        No economy data yet. Join an event or play a match to start tracking.
      </.empty_state>

      <div
        :if={@inventory || @entries != [] || @transactions != []}
        class="space-y-8"
      >
        <%!-- Current balance cards --%>
        <div :if={@inventory} class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-4">
          <.stat_card title="Gold" value={EconomyHelpers.format_number(@inventory.gold || 0)} />
          <.stat_card title="Gems" value={EconomyHelpers.format_number(@inventory.gems || 0)} />
          <.stat_card title="Common WC" value={@inventory.wildcards_common || 0} />
          <.stat_card title="Uncommon WC" value={@inventory.wildcards_uncommon || 0} />
          <.stat_card title="Rare WC" value={@inventory.wildcards_rare || 0} />
          <.stat_card title="Mythic WC" value={@inventory.wildcards_mythic || 0} />
          <.stat_card
            title="Vault"
            value={"#{Float.round((@inventory.vault_progress || 0) / 1, 1)}%"}
          />
        </div>

        <%!-- Event entries / ROI --%>
        <section :if={@entries != []}>
          <h2 class="text-lg font-semibold mb-3">Event History</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Event</th>
                  <th class="text-right">Entry Fee</th>
                  <th class="text-right">Record</th>
                  <th class="text-right">Gems Won</th>
                  <th class="text-right">Gold Won</th>
                  <th class="text-right">Net ROI</th>
                  <th>Joined</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @entries}>
                  <td>{format_label(entry.event_name)}</td>
                  <td class="text-right tabular-nums">
                    {EconomyHelpers.format_currency(entry.entry_fee, entry.entry_currency_type || "")}
                  </td>
                  <td class="text-right tabular-nums">
                    {if entry.final_wins, do: "#{entry.final_wins}–#{entry.final_losses}", else: "—"}
                  </td>
                  <td class="text-right tabular-nums">
                    {EconomyHelpers.format_delta(entry.gems_awarded)}
                  </td>
                  <td class="text-right tabular-nums">
                    {EconomyHelpers.format_delta(entry.gold_awarded)}
                  </td>
                  <td class="text-right tabular-nums font-semibold">
                    {EconomyHelpers.format_roi(entry)}
                  </td>
                  <td class="tabular-nums">{format_datetime(entry.joined_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- Recent transactions --%>
        <section :if={@transactions != []}>
          <h2 class="text-lg font-semibold mb-3">Recent Transactions</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Source</th>
                  <th class="text-right">Gold</th>
                  <th class="text-right">Gems</th>
                  <th class="text-right">Balance (G)</th>
                  <th class="text-right">Balance (💎)</th>
                  <th>Time</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={transaction <- @transactions}>
                  <td>{format_label(transaction.source)}</td>
                  <td class={[
                    "text-right tabular-nums",
                    EconomyHelpers.delta_class(transaction.gold_delta)
                  ]}>
                    {EconomyHelpers.format_delta(transaction.gold_delta)}
                  </td>
                  <td class={[
                    "text-right tabular-nums",
                    EconomyHelpers.delta_class(transaction.gems_delta)
                  ]}>
                    {EconomyHelpers.format_delta(transaction.gems_delta)}
                  </td>
                  <td class="text-right tabular-nums">
                    {EconomyHelpers.format_number(transaction.gold_balance || 0)}
                  </td>
                  <td class="text-right tabular-nums">
                    {EconomyHelpers.format_number(transaction.gems_balance || 0)}
                  </td>
                  <td class="tabular-nums">{format_datetime(transaction.occurred_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
