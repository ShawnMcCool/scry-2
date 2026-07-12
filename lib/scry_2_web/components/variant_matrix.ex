defmodule Scry2Web.Components.VariantMatrix do
  @moduledoc """
  The variant matrix on the netdeck detail page (UIDR-014): contested
  nonland cards (rows, most-contested first) × cluster members (columns,
  best finish first), every cell a copy delta relative to the viewed deck.

  The card-name and `you ×N` columns form a frozen pane; the field scrolls
  horizontally inside the section. Column heads carry the pilot name as
  real text (browser find must land on it) and navigate to that variant.
  Cells use tinted text only — no fills (UIDR-008). Manabase, sideboard,
  and total-delta magnitudes render as footer rows.
  """

  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: Scry2Web.Endpoint, router: Scry2Web.Router

  alias Scry2.NetDecking.Provenance
  alias Scry2Web.NetdecksHelpers

  @frozen_name_width "13rem"
  @frozen_you_offset "13rem"

  attr :matrix, :map, required: true, doc: "VariantMatrix view model: %{rows, columns}"

  def variant_matrix(assigns) do
    assigns =
      assign(assigns,
        name_width: @frozen_name_width,
        you_offset: @frozen_you_offset,
        cluster_size: length(assigns.matrix.columns) + 1
      )

    ~H"""
    <div :if={@matrix.columns != []}>
      <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
        Variant matrix ({@cluster_size} lists)
      </h3>
      <p class="text-xs text-base-content/45 mb-3 max-w-prose">
        Every other list in this cluster, one column each, best finish first. Cells show copies
        relative to this list — <span class="text-success/80">+n</span>
        more, <span class="text-error/80">−n</span>
        fewer, blank same.
      </p>
      <div
        class="overflow-x-auto rounded-xl bg-base-200/60 border border-base-300/40"
        id="variant-matrix"
        phx-hook="VariantMatrix"
      >
        <table class="border-collapse w-max text-xs">
          <thead>
            <tr>
              <th
                class="sticky left-0 z-[3] bg-base-200 text-left align-bottom pb-2 pl-4 pr-2 font-semibold text-base-content/35 uppercase tracking-widest"
                style={"min-width: #{@name_width}; max-width: #{@name_width};"}
              >
                Contested cards
              </th>
              <th
                class="sticky z-[3] bg-base-200 align-bottom pb-2 px-1 font-semibold uppercase tracking-widest text-primary/80 border-r border-base-300/70"
                style={"left: #{@you_offset}; min-width: 3rem;"}
              >
                you
              </th>
              <th
                :for={column <- @matrix.columns}
                class="align-bottom pb-1.5 font-normal min-w-8"
                data-col
              >
                <.link
                  patch={~p"/netdecks/#{column.deck.id}"}
                  class="block hover:text-base-content"
                  title={column_title(column.deck)}
                >
                  <span class="block mx-auto max-h-24 overflow-hidden text-base-content/50 [writing-mode:vertical-rl] rotate-180 whitespace-nowrap text-[11px]">
                    {column.deck.pilot || column.deck.name}
                  </span>
                  <span class="block text-center mt-1 text-[10px] text-base-content/40 tabular-nums">
                    {Provenance.compact_finish_label(column.deck) || "—"}
                  </span>
                </.link>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @matrix.rows}
              class="border-t border-base-300/30 hover:bg-base-content/5 group"
            >
              <td
                class="sticky left-0 z-[2] bg-base-200 group-hover:bg-base-200 py-1.5 pl-4 pr-2 whitespace-nowrap overflow-hidden text-ellipsis text-[13px]"
                style={"min-width: #{@name_width}; max-width: #{@name_width};"}
              >
                <span class={["inline-block size-1.5 rounded-full mr-1.5", rarity_dot(row.rarity)]} />
                {row.name}
              </td>
              <td
                class="sticky z-[2] bg-base-200 group-hover:bg-base-200 text-center font-semibold text-primary/80 tabular-nums border-r border-base-300/70"
                style={"left: #{@you_offset};"}
              >
                ×{row.you_count}
              </td>
              <td
                :for={column <- @matrix.columns}
                class={["text-center tabular-nums h-7 min-w-8", delta_tone(column.deltas[row.name])]}
                data-col
              >
                <span :if={column.deltas[row.name]}>
                  {NetdecksHelpers.matrix_delta_label(column.deltas[row.name])}
                </span>
              </td>
            </tr>
          </tbody>
          <tfoot>
            <.magnitude_row
              label="Manabase"
              values={Enum.map(@matrix.columns, & &1.lands_changed)}
              name_width={@name_width}
              you_offset={@you_offset}
            />
            <.magnitude_row
              label="Sideboard"
              values={Enum.map(@matrix.columns, & &1.sideboard_changed)}
              name_width={@name_width}
              you_offset={@you_offset}
            />
            <tr class="border-t border-base-300/60">
              <td
                class="sticky left-0 z-[2] bg-base-200 py-1.5 pl-4 pr-2 text-[11px] uppercase tracking-widest text-base-content/50"
                style={"min-width: #{@name_width}; max-width: #{@name_width};"}
              >
                Total Δ
              </td>
              <td
                class="sticky z-[2] bg-base-200 border-r border-base-300/70"
                style={"left: #{@you_offset};"}
              >
              </td>
              <td
                :for={column <- @matrix.columns}
                class="text-center tabular-nums text-base-content/60 min-w-8"
                data-col
              >
                {column.total_changed}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :values, :list, required: true
  attr :name_width, :string, required: true
  attr :you_offset, :string, required: true

  defp magnitude_row(assigns) do
    ~H"""
    <tr class="border-t border-base-300/50">
      <td
        class="sticky left-0 z-[2] bg-base-200 py-1 pl-4 pr-2 text-[11px] uppercase tracking-widest text-base-content/35"
        style={"min-width: #{@name_width}; max-width: #{@name_width};"}
      >
        {@label}
      </td>
      <td class="sticky z-[2] bg-base-200 border-r border-base-300/70" style={"left: #{@you_offset};"}>
      </td>
      <td
        :for={value <- @values}
        class="text-center tabular-nums text-base-content/40 min-w-8"
        data-col
      >
        {NetdecksHelpers.matrix_magnitude_label(value)}
      </td>
    </tr>
    """
  end

  @doc "Column-head tooltip: pilot, finish, and record — whatever exists."
  @spec column_title(Scry2.NetDecking.Deck.t()) :: String.t()
  def column_title(deck) do
    [
      deck.pilot || deck.name,
      Provenance.finish_label(deck),
      Provenance.record_label(deck)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Hues follow the established rarity palette (RecentCraftsCard chips).
  @doc "Rarity-dot tone class for a matrix row label."
  @spec rarity_dot(String.t() | nil) :: String.t()
  def rarity_dot("mythic"), do: "bg-red-400/70"
  def rarity_dot("rare"), do: "bg-amber-400/70"
  def rarity_dot("uncommon"), do: "bg-blue-400/70"
  def rarity_dot(_rarity), do: "bg-base-content/40"

  @doc "Cell text tone: additions succeed-tinted, cuts error-tinted, same blank."
  @spec delta_tone(integer() | nil) :: String.t() | nil
  def delta_tone(nil), do: nil
  def delta_tone(delta) when delta > 0, do: "text-success/80"
  def delta_tone(delta) when delta < 0, do: "text-error/80"
end
