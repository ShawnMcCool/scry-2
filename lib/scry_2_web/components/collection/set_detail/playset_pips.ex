defmodule Scry2Web.Collection.SetDetail.PlaysetPips do
  @moduledoc """
  Four-dot indicator showing how many copies of a card are owned out of
  a playset of 4. Filled dot = owned, faint dot = needed.
  """

  use Phoenix.Component

  attr :count, :integer, required: true
  attr :playset, :integer, default: 4
  attr :class, :string, default: nil

  def playset_pips(assigns) do
    ~H"""
    <div
      class={["inline-flex items-center gap-0.5", @class]}
      aria-label={"#{shown(@count, @playset)} of #{@playset}"}
      title={"#{shown(@count, @playset)} of #{@playset}"}
      data-role="playset-pips"
      data-count={@count}
    >
      <span
        :for={i <- 1..@playset}
        class={[
          "block size-2 rounded-full",
          if(i <= @count, do: "bg-base-content/80", else: "bg-base-content/15")
        ]}
      />
    </div>
    """
  end

  defp shown(count, playset) when is_integer(count) and is_integer(playset),
    do: min(count, playset)
end
