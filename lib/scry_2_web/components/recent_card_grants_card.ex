defmodule Scry2Web.Components.RecentCardGrantsCard do
  @moduledoc """
  Recent-card-grants list card on the Economy page.

  One row per detected `CardsGranted` event. Each row shows the
  human-readable source label (e.g. "Event prize", "Voucher"), the
  granted cards (name with vault-progress note for duplicates), and
  the relative time the grant occurred.

  Logic-bearing helpers `source_label/1` and `format_grant_card/2`
  are exposed for unit testing per ADR-013.
  """

  use Phoenix.Component

  import Scry2Web.LiveHelpers

  alias Scry2.Economy.CardGrant

  attr :grants, :list, required: true
  attr :cards_by_arena_id, :map, required: true

  def recent_card_grants_card(assigns) do
    ~H"""
    <section :if={@grants != []} data-test="recent-card-grants-card">
      <h2 class="text-lg font-semibold mb-3 font-beleren">Recent Card Grants</h2>
      <ul class="rounded-lg border border-base-content/5 divide-y divide-base-content/5">
        <li :for={grant <- @grants} class="flex flex-col gap-1 px-4 py-3">
          <div class="flex items-center gap-2 text-sm">
            <span class="font-medium">{grant_label(grant)}</span>
            <span class="text-base-content/40 text-xs">·</span>
            <span class="text-xs text-base-content/50">{relative_time(grant.occurred_at)}</span>
            <span class="text-base-content/40 text-xs">·</span>
            <span class="text-xs text-base-content/50 tabular-nums">
              {grant.card_count} {if grant.card_count == 1, do: "card", else: "cards"}
            </span>
          </div>
          <ul class="flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-base-content/70">
            <li
              :for={row <- CardGrant.unwrap_cards(grant.cards)}
              class="truncate max-w-[20rem]"
            >
              {format_grant_card(row, @cards_by_arena_id)}
            </li>
          </ul>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  Renders the player-facing header for a grant row, combining the
  grant's `source` with its `source_id` where appropriate.

  Pack-open grants stamp `source_id` with the booster's set code
  (e.g., `"BLB"`); when present, render as `"BLB pack opened"` so
  the player knows which set was opened. Falls through to
  `source_label/1` for everything else.
  """
  @spec grant_label(%{source: String.t() | nil, source_id: String.t() | nil}) :: String.t()
  def grant_label(%{source: "MemoryDiff:PackOpen", source_id: set_code})
      when is_binary(set_code) and set_code != "" do
    "#{set_code} pack opened"
  end

  def grant_label(%{source: source}), do: source_label(source)

  @doc """
  Map MTGA's verbatim `Source` code to a player-readable label.

  Unknown sources fall through to a humanised version of the
  source code (e.g. `"FooBar"` → `"Foo bar"`).
  """
  @spec source_label(String.t() | nil) :: String.t()
  def source_label("EventReward"), do: "Event prize"
  def source_label("EventGrantCardPool"), do: "Draft pool grant"
  def source_label("RedeemVoucher"), do: "Voucher"
  def source_label("LoginGrant"), do: "Login bonus"
  def source_label("EventPayEntry"), do: "Event entry refund"
  def source_label("MemoryDiff"), do: "Detected from collection"
  def source_label("MemoryDiff:PackOpen"), do: "Pack opened"
  def source_label(nil), do: "Unknown source"

  def source_label(other) when is_binary(other) do
    other
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.capitalize()
  end

  @doc """
  Format a single granted-card row for display. Resolves the card
  name from `cards_by_arena_id`; falls back to `"#<arena_id>"`.
  Annotates duplicates that contributed to vault progress instead
  of joining the collection.
  """
  @spec format_grant_card(map(), map()) :: String.t()
  def format_grant_card(row, cards_by_arena_id) do
    arena_id = row["arena_id"] || row[:arena_id]
    name = name_for_arena_id(cards_by_arena_id, arena_id)

    cond do
      vault_progress?(row) -> "#{name} (vault)"
      true -> name
    end
  end

  defp vault_progress?(row) do
    progress = row["vault_progress"] || row[:vault_progress] || 0
    is_integer(progress) and progress > 0
  end

  defp name_for_arena_id(cards_by_arena_id, arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      %{name: name} -> name
      %{"name" => name} -> name
      _ -> "##{arena_id}"
    end
  end
end
