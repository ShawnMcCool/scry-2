defmodule Scry2Web.Collection.HoldingSummary do
  @moduledoc """
  KPI tiles summarising the size of a collection: unique cards, total
  copies, and the number of complete playsets.

  Pure renderer over a `[Scry2.Collection.Holding.t()]`.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [stat_card: 1]

  attr :holdings, :list, required: true

  def holding_summary(assigns) do
    holdings = assigns.holdings

    assigns =
      assign(assigns,
        unique: length(holdings),
        copies: Enum.reduce(holdings, 0, &(&1.count + &2)),
        playsets: Enum.count(holdings, &(&1.count >= 4))
      )

    ~H"""
    <div
      class="grid grid-cols-2 sm:grid-cols-3 gap-4"
      data-role="holding-summary"
    >
      <.stat_card title="Unique cards" value={format_number(@unique)} data-stat="unique" />
      <.stat_card title="Total copies" value={format_number(@copies)} data-stat="copies" />
      <.stat_card title="Playsets" value={format_number(@playsets)} data-stat="playsets" />
    </div>
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(other), do: to_string(other)
end
