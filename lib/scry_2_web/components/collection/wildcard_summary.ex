defmodule Scry2Web.Collection.WildcardSummary do
  @moduledoc """
  KPI tiles for the four wildcard rarities and vault progress.

  Pure renderer over a `Scry2.Collection.Snapshot.t()`. Walker-only fields
  are nil for fallback-scan snapshots; the component renders an em-dash in
  that case rather than a misleading zero.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [stat_card: 1, wildcard_icon: 1]

  alias Scry2.Collection.Snapshot

  attr :snapshot, :any, required: true

  def wildcard_summary(%{snapshot: nil} = assigns), do: ~H""

  def wildcard_summary(%{snapshot: %Snapshot{}} = assigns) do
    ~H"""
    <div
      class="grid grid-cols-2 sm:grid-cols-5 gap-4"
      data-role="wildcard-summary"
    >
      <.stat_card title="Common" value={format(@snapshot.wildcards_common)} data-stat="wc-common">
        <:icon><.wildcard_icon rarity="common" /></:icon>
      </.stat_card>
      <.stat_card
        title="Uncommon"
        value={format(@snapshot.wildcards_uncommon)}
        data-stat="wc-uncommon"
      >
        <:icon><.wildcard_icon rarity="uncommon" /></:icon>
      </.stat_card>
      <.stat_card title="Rare" value={format(@snapshot.wildcards_rare)} data-stat="wc-rare">
        <:icon><.wildcard_icon rarity="rare" /></:icon>
      </.stat_card>
      <.stat_card title="Mythic" value={format(@snapshot.wildcards_mythic)} data-stat="wc-mythic">
        <:icon><.wildcard_icon rarity="mythic" /></:icon>
      </.stat_card>
      <.stat_card title="Vault" value={format_vault(@snapshot.vault_progress)} data-stat="vault" />
    </div>
    """
  end

  defp format(nil), do: "—"
  defp format(n) when is_integer(n), do: Integer.to_string(n)

  defp format_vault(nil), do: "—"

  defp format_vault(progress) when is_float(progress) or is_integer(progress) do
    "#{Float.round(progress * 100, 1)}%"
  end
end
