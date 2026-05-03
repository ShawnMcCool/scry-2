defmodule Scry2Web.Live.MatchBoardView do
  @moduledoc """
  Pure helpers for rendering the per-match Chain-2 revealed-cards
  section on the match detail page.

  Logic-bearing functions live here (and are unit-tested) per
  ADR-013; the LiveView template only wires them in. The functions
  take plain data (lists of `%RevealedCard{}`) and return display-
  ready shapes — no Ecto queries, no PubSub, no template rendering.

  ## Shape

  `group_by_seat_and_zone/1` returns a list of `%{seat_id, zones:
  [%{zone_id, label, arena_ids}]}` maps. Empty seats are omitted;
  empty zones within a present seat are omitted. The list is ordered
  with the local player first (`seat_id == 1`), the opponent second
  (`seat_id == 2`), and any other seats in numeric order after that.
  """

  alias Scry2.LiveState.RevealedCard

  @typedoc "Per-(seat, zone) display row."
  @type zone_row :: %{
          zone_id: integer(),
          label: String.t(),
          arena_ids: [integer()]
        }

  @typedoc "Per-seat group of zone rows."
  @type seat_group :: %{
          seat_id: integer(),
          label: String.t(),
          zones: [zone_row()]
        }

  @local_seat_id 1
  @opponent_seat_id 2

  @doc """
  Group revealed-card rows into per-seat, per-zone display rows.

  Input: `[%RevealedCard{}]` from `LiveState.get_revealed_cards_by_match_id/1`
  (already ordered by seat_id, zone_id, position).

  Output: `[seat_group()]` ordered local first, opponent second,
  others in seat-id order.
  """
  @spec group_by_seat_and_zone([RevealedCard.t()]) :: [seat_group()]
  def group_by_seat_and_zone([]), do: []

  def group_by_seat_and_zone(rows) when is_list(rows) do
    rows
    |> Enum.group_by(& &1.seat_id)
    |> Enum.map(fn {seat_id, seat_rows} ->
      %{
        seat_id: seat_id,
        label: seat_label(seat_id),
        zones: build_zones(seat_rows)
      }
    end)
    |> Enum.reject(&(&1.zones == []))
    |> Enum.sort_by(&seat_sort_key/1)
  end

  @doc """
  Symbolic name for an MTGA seat-id enum value. Falls back to
  `"Seat <n>"` for unknown values so the UI never shows a bare
  integer.
  """
  @spec seat_label(integer()) :: String.t()
  def seat_label(@local_seat_id), do: "You"
  def seat_label(@opponent_seat_id), do: "Opponent"
  def seat_label(0), do: "Unknown"
  def seat_label(3), do: "Teammate"
  def seat_label(other) when is_integer(other), do: "Seat #{other}"

  @doc """
  Symbolic name for an MTGA zone-id enum value (CardHolderType
  enum). Falls back to `"Zone <n>"` for unknown values.

  Per the Chain-2 spec v1, only Battlefield (zone 4) is populated;
  this helper still names every documented zone so v2 lands
  cleanly.
  """
  @spec zone_label(integer()) :: String.t()
  def zone_label(1), do: "Library"
  def zone_label(2), do: "Off-camera Library"
  def zone_label(3), do: "Hand"
  def zone_label(4), do: "Battlefield"
  def zone_label(5), do: "Graveyard"
  def zone_label(6), do: "Exile"
  def zone_label(9), do: "Stack"
  def zone_label(10), do: "Command"
  def zone_label(other) when is_integer(other), do: "Zone #{other}"

  defp build_zones(rows) do
    rows
    |> Enum.group_by(& &1.zone_id)
    |> Enum.map(fn {zone_id, zone_rows} ->
      %{
        zone_id: zone_id,
        label: zone_label(zone_id),
        arena_ids: zone_rows |> Enum.sort_by(& &1.position) |> Enum.map(& &1.arena_id)
      }
    end)
    |> Enum.reject(&(&1.arena_ids == []))
    |> Enum.sort_by(& &1.zone_id)
  end

  # Local first (1), opponent second (2), then others in numeric order.
  # Use a tuple sort key so 0 ("Invalid"), 3 ("Teammate"), etc. sort
  # cleanly after the two main seats.
  defp seat_sort_key(%{seat_id: @local_seat_id}), do: {0, 0}
  defp seat_sort_key(%{seat_id: @opponent_seat_id}), do: {0, 1}
  defp seat_sort_key(%{seat_id: other}), do: {1, other}
end
