defmodule Scry2Web.Components.CosmeticsCard.Helpers do
  @moduledoc """
  Pure formatters for `Scry2Web.Components.CosmeticsCard`. Extracted
  per ADR-013 so the card stays thin and the per-row formatting gets
  standalone tests with `async: true` and no DB.
  """

  @rarities [
    {:art_styles, "Alt arts"},
    {:avatars, "Avatars"},
    {:pets, "Pets"},
    {:sleeves, "Sleeves"},
    {:emotes, "Emotes"},
    {:titles, "Titles"}
  ]

  @doc """
  Returns `true` when the card should render — i.e. the decoded
  cosmetics map carries a non-empty `available` block. We treat
  "all-zero available counts" as the same as "no data": MTGA's
  master catalog can't actually be empty, so an all-zero read is
  a stale-snapshot signal.
  """
  @spec has_data?(map() | nil) :: boolean()
  def has_data?(nil), do: false
  def has_data?(%{available: nil}), do: false

  def has_data?(%{available: %{} = available}) do
    Enum.any?(
      [
        :art_styles,
        :avatars,
        :pets,
        :sleeves,
        :emotes,
        :titles
      ],
      fn key -> Map.get(available, key, 0) > 0 end
    )
  end

  def has_data?(_), do: false

  @doc """
  Returns the per-category rows for rendering: a list of
  `{label, owned, available, percent}` tuples, ordered by category.

  Categories whose `available` count is `0` are filtered out — that
  signals the master list isn't hydrated yet (Titles, in particular,
  loads lazily on first UI access; see spike22 FINDING). Showing
  `0 / 0` for a stub category is misleading; hiding it is honest.
  """
  @spec rows(map() | nil) :: [
          {label :: String.t(), owned :: non_neg_integer(), available :: non_neg_integer(),
           percent :: integer()}
        ]
  def rows(nil), do: []

  def rows(%{available: %{} = avail, owned: %{} = owned}) do
    @rarities
    |> Enum.map(fn {key, label} ->
      a = Map.get(avail, key, 0) || 0
      o = Map.get(owned, key, 0) || 0
      p = if a > 0, do: trunc(o * 100 / a), else: 0
      {label, o, a, p}
    end)
    |> Enum.reject(fn {_label, _owned, available, _pct} -> available == 0 end)
  end

  def rows(_), do: []

  @doc """
  Formats an integer with comma separators. Mirrors
  `EconomyHelpers.format_number/1` so the card is self-contained
  (no cross-component formatting dependency).
  """
  @spec format_count(integer()) :: String.t()
  def format_count(n) when is_integer(n) and n < 0, do: "-" <> format_count(-n)

  def format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end
end

defmodule Scry2Web.Components.CosmeticsCard do
  @moduledoc """
  Cosmetics inventory card on `/economy`. Renders a compact table of
  per-category "owned / total" counts plus a small progress bar per
  row, sourced from the latest collection snapshot's
  `cosmetics_json` blob (memory-read via the cosmetics walker —
  spike 22).

  Hides itself when no usable data is present (pre-login, walker
  unreachable). All formatters live in `CosmeticsCard.Helpers` per
  ADR-013.
  """

  use Phoenix.Component

  alias Scry2.Collection.Snapshot
  alias Scry2Web.Components.CosmeticsCard.Helpers, as: H

  attr :snapshot, :any,
    required: true,
    doc: "Latest %Snapshot{} or nil. Empty state if nil or cosmetics_json absent."

  def cosmetics_card(assigns) do
    decoded = decode(assigns[:snapshot])
    rows = H.rows(decoded)

    assigns =
      assigns
      |> assign(:decoded, decoded)
      |> assign(:rows, rows)
      |> assign(:visible, H.has_data?(decoded))

    ~H"""
    <section
      :if={@visible}
      class="card bg-base-200 border border-base-300"
      data-role="cosmetics-card"
    >
      <div class="card-body">
        <h2 class="card-title">Cosmetics</h2>
        <p class="text-xs text-base-content/60 mb-3">
          Memory-read inventory across the six MTGA cosmetic categories.
        </p>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/40">
                <th>Category</th>
                <th class="text-right">Owned</th>
                <th class="text-right">Total</th>
                <th>Progress</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{label, owned, available, percent} <- @rows}>
                <td class="font-medium">{label}</td>
                <td class="text-right tabular-nums">{H.format_count(owned)}</td>
                <td class="text-right tabular-nums text-base-content/50">
                  {H.format_count(available)}
                </td>
                <td>
                  <div class="flex items-center gap-2 min-w-32">
                    <div class="w-full bg-base-300 rounded-full h-1.5">
                      <div
                        class="bg-primary h-1.5 rounded-full"
                        style={"width: #{percent}%"}
                      />
                    </div>
                    <span class="text-xs tabular-nums text-base-content/60 w-10 text-right">
                      {percent}%
                    </span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp decode(%{cosmetics_json: json}) when is_binary(json),
    do: Snapshot.decode_cosmetics(json)

  defp decode(_), do: nil
end
