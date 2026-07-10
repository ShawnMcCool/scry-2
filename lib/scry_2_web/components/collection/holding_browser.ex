defmodule Scry2Web.Collection.HoldingBrowser do
  @moduledoc """
  Searchable, filter-chipped grid of owned cards. Each tile shows the
  card image, rarity badge, name, and a count-of-four playset badge.

  Pure renderer over a `[Scry2.Collection.Holding.t()]` plus the active
  filters and the host's `@cached_card_ids` map (see
  `Scry2Web.CardImages`) for image presence.

  Host LiveView events:

    * `phx-change="search"` (form input named `search`) — text search.
    * `phx-click="clear_search"` — clear text search.
    * `phx-click="toggle_rarity" phx-value-rarity={rarity}` — chip toggle.
    * `phx-click="clear_set"` — drop the `?set=` URL scope.
  """

  use Phoenix.Component

  import Scry2Web.CardComponents, only: [card_image: 1, card_name: 1]
  import Scry2Web.CoreComponents, only: [icon: 1, rarity_badge: 1, set_label: 1]

  @rarities ~w(mythic rare uncommon common)

  attr :holdings, :list, required: true
  attr :total_count, :integer, required: true
  attr :search, :string, default: ""
  attr :rarities, :any, default: nil
  attr :active_set, :any, default: nil
  attr :active_set_record, :any, default: nil
  attr :cached_ids, :any, default: nil

  def holding_browser(assigns) do
    rarities = assigns.rarities || MapSet.new()

    assigns =
      assign(assigns,
        rarities: rarities,
        all_rarities: @rarities
      )

    ~H"""
    <div class="card bg-base-200 border border-base-300" data-role="holding-browser">
      <div class="card-body space-y-3">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title">My cards</h2>
          <span :if={@active_set} class="flex items-center gap-2 text-xs min-w-0">
            <span class="badge badge-soft badge-primary max-w-[16rem]">
              <.set_label set={@active_set_record || %{code: @active_set, name: @active_set}} />
            </span>
            <button class="link shrink-0" phx-click="clear_set">Clear</button>
          </span>
        </div>

        <div class="flex items-center gap-3">
          <form phx-change="search" phx-submit="search" class="relative flex-1">
            <input
              type="text"
              name="search"
              placeholder="Search owned cards…"
              value={@search}
              phx-debounce="150"
              class="input input-bordered w-full pr-8"
            />
            <button
              :if={@search != ""}
              phx-click="clear_search"
              class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content"
              aria-label="Clear search"
              type="button"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </form>
        </div>

        <div class="flex items-center gap-2" data-role="rarity-chips">
          <button
            :for={rarity <- @all_rarities}
            type="button"
            phx-click="toggle_rarity"
            phx-value-rarity={rarity}
            class={[
              "btn btn-xs",
              if(MapSet.member?(@rarities, rarity), do: "btn-primary", else: "btn-ghost")
            ]}
            data-rarity={rarity}
          >
            {String.capitalize(rarity)}
          </button>
        </div>

        <p class="text-xs text-base-content/60 tabular-nums">
          Showing {length(@holdings)} of {@total_count} owned cards.
        </p>

        <div :if={@holdings == []} class="py-8 text-center text-base-content/40 text-sm">
          No owned cards match the active filters.
        </div>

        <div
          :if={@holdings != []}
          class="grid gap-2"
          style="grid-template-columns: repeat(auto-fill, minmax(7.5rem, 1fr))"
        >
          <div
            :for={holding <- @holdings}
            class="flex flex-col gap-1 relative"
            data-role="holding-tile"
            data-arena-id={holding.arena_id}
          >
            <div class="relative">
              <.card_image
                arena_id={holding.arena_id}
                name={holding.card.name || ""}
                class="w-full"
                cached_ids={@cached_ids}
              />
              <span
                class={[
                  "absolute top-1 right-1 badge badge-sm tabular-nums",
                  count_badge_class(holding.count)
                ]}
                title={"#{holding.count} of 4"}
              >
                {holding.count}/4
              </span>
            </div>
            <.card_name
              arena_id={holding.arena_id}
              name={holding.card.name || "—"}
              id={"holding-name-#{holding.arena_id}"}
              class="text-xs truncate"
              cached_ids={@cached_ids}
            />
            <.rarity_badge rarity={holding.card.rarity || "common"} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp count_badge_class(count) when count >= 4, do: "badge-soft badge-success"
  defp count_badge_class(count) when count >= 2, do: "badge-soft badge-warning"
  defp count_badge_class(_), do: "badge-soft badge-error"
end
