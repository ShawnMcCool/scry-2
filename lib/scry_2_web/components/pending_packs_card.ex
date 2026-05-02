defmodule Scry2Web.Components.PendingPacksCard do
  @moduledoc """
  Pending booster inventory card on the Economy page.

  Renders one row per set the player has unopened packs of, sorted
  by count desc, with the total at the bottom. Driven by
  `Scry2.Collection.PendingPacks.summarize/2` over the latest
  collection snapshot.

  The set code is the join key (`SetLogo_<SET>.png` from
  `MTGA_Data/Downloads/ALT/ALT_Booster_*.mtga`); resolved to a
  `<.set_icon>` glyph + the bare code. Unknown collation_ids fall
  into a single "Unknown set" row.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents

  alias Scry2.Collection.PendingPacks

  attr :rows, :list, required: true

  def pending_packs_card(assigns) do
    assigns = assign(assigns, :total, PendingPacks.total(assigns.rows))

    ~H"""
    <section :if={@rows != []} data-test="pending-packs-card">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-lg font-semibold font-beleren">Pending Packs</h2>
        <span class="text-xs text-base-content/50 tabular-nums">
          {@total} {if @total == 1, do: "pack", else: "packs"} total
        </span>
      </div>
      <ul class="rounded-lg border border-base-content/5 divide-y divide-base-content/5">
        <li
          :for={row <- @rows}
          class="flex items-center justify-between px-4 py-2.5"
        >
          <div class="flex items-center gap-2 text-sm">
            <.set_icon
              :if={row.set_code}
              code={row.set_code}
              class="text-base-content/60"
            />
            <span class="font-medium">
              {row_label(row)}
            </span>
          </div>
          <span class="text-sm tabular-nums text-base-content/70">
            {row.count}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  @doc "Label for a pending-packs row — falls back to 'Unknown set' for unmapped collation_ids."
  @spec row_label(%{set_code: String.t() | nil}) :: String.t()
  def row_label(%{set_code: nil}), do: "Unknown set"
  def row_label(%{set_code: code}), do: code
end
