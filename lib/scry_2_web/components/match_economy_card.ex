defmodule Scry2Web.Components.MatchEconomyCard do
  @moduledoc """
  Per-match economy delta card. Renders the Summary's three states
  (complete + matched, complete + diff, partial / log_only / incomplete).

  Logic-bearing helper `currency_rows/1` is exposed for unit testing
  per ADR-013 (no HTML assertions; test the pure helper).
  """

  use Phoenix.Component
  alias Scry2.MatchEconomy.Summary

  attr :summary, Summary, required: true

  def card(assigns) do
    assigns = assign(assigns, :rows, currency_rows(assigns.summary))

    ~H"""
    <div class="card bg-base-200 shadow-sm" data-test="match-economy-card">
      <div class="card-body p-4">
        <h3 class="card-title text-sm uppercase tracking-wide opacity-70">
          Match economy
        </h3>

        <div
          :if={@summary.reconciliation_state == "incomplete"}
          class="text-sm opacity-70"
        >
          Capture incomplete — memory or log data unavailable for this match.
        </div>

        <div
          :if={@summary.reconciliation_state != "incomplete"}
          class="overflow-x-auto"
        >
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Currency</th>
                <th>Memory</th>
                <th>Log</th>
                <th>Diff</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td>{row.label}</td>
                <td>{format(row.memory)}</td>
                <td>{format(row.log)}</td>
                <td>
                  <span
                    :if={row.diff != nil and row.diff != 0}
                    class="badge badge-soft badge-warning"
                  >
                    {format(row.diff)}
                  </span>
                  <span :if={row.diff == 0} class="opacity-50">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  def currency_rows(%Summary{} = summary) do
    [
      %{
        label: "Gold",
        memory: summary.memory_gold_delta,
        log: summary.log_gold_delta,
        diff: summary.diff_gold
      },
      %{
        label: "Gems",
        memory: summary.memory_gems_delta,
        log: summary.log_gems_delta,
        diff: summary.diff_gems
      },
      %{
        label: "Common WC",
        memory: summary.memory_wildcards_common_delta,
        log: summary.log_wildcards_common_delta,
        diff: summary.diff_wildcards_common
      },
      %{
        label: "Uncommon WC",
        memory: summary.memory_wildcards_uncommon_delta,
        log: summary.log_wildcards_uncommon_delta,
        diff: summary.diff_wildcards_uncommon
      },
      %{
        label: "Rare WC",
        memory: summary.memory_wildcards_rare_delta,
        log: summary.log_wildcards_rare_delta,
        diff: summary.diff_wildcards_rare
      },
      %{
        label: "Mythic WC",
        memory: summary.memory_wildcards_mythic_delta,
        log: summary.log_wildcards_mythic_delta,
        diff: summary.diff_wildcards_mythic
      },
      %{label: "Vault", memory: summary.memory_vault_delta, log: nil, diff: nil}
    ]
  end

  defp format(nil), do: "—"
  defp format(0), do: "—"
  defp format(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp format(n) when is_integer(n), do: "#{n}"
  defp format(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
end
