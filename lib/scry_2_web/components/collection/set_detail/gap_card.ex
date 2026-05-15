defmodule Scry2Web.Collection.SetDetail.GapCard do
  @moduledoc """
  One card tile in the gap list — image, name, playset pip indicator.
  """

  use Phoenix.Component

  import Scry2Web.CardComponents, only: [card_image: 1]
  import Scry2Web.Collection.SetDetail.PlaysetPips, only: [playset_pips: 1]

  attr :card, :map, required: true
  attr :count, :integer, required: true
  attr :cached_arena_ids, :any, default: nil

  def gap_card(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-1 w-[5.5rem]" data-role="gap-card">
      <.card_image
        arena_id={@card.arena_id}
        name={@card.name}
        class="w-[5.5rem]"
        cached_ids={@cached_arena_ids}
      />
      <span
        class="text-[10px] text-base-content/70 truncate w-full text-center"
        title={@card.name}
      >
        {@card.name}
      </span>
      <.playset_pips count={@count} />
    </div>
    """
  end
end
