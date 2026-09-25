defmodule Scry2Web.Live.MatchBoardView do
  @moduledoc """
  Pure helpers for rendering the per-match revealed-cards section on the
  match detail page.

  Logic-bearing functions live here (and are unit-tested) per ADR-013;
  the LiveView template only wires them in. The functions take plain data
  (lists of `%Scry2.Matches.RevealedCard{}`) and return display-ready
  shapes — no Ecto queries, no PubSub, no template rendering.

  ## Shape

  `group_by_seat_and_zone/1` returns a list of `%{seat_id, label, zones:
  [%{zone, label, arena_ids}]}` maps. Empty seats are omitted; empty
  zones within a present seat are omitted. The list is ordered with the
  local player first, the opponent second, and any seat whose role could
  not be resolved after that — by role, never by GRE seat number, which
  alternates between matches.

  Zones are semantic slugs from the GRE zone table (`"battlefield"`,
  `"hand"`, …) rather than MTGA `CardHolderType` integers — the data now
  comes from the domain event log, not process memory. See ADR-047.
  """

  alias Scry2.Matches.RevealedCard

  @typedoc "Per-(seat, zone) display row."
  @type zone_row :: %{
          zone: String.t() | nil,
          label: String.t(),
          arena_ids: [integer()]
        }

  @typedoc "Per-seat group of zone rows."
  @type seat_group :: %{
          seat_id: integer(),
          is_local: boolean() | nil,
          label: String.t(),
          zones: [zone_row()]
        }

  # Display order for the zones a player actually looks at, then
  # everything else alphabetically after.
  @zone_order ~w(battlefield hand graveyard exile stack library command sideboard revealed)

  @doc """
  Group revealed-card rows into per-seat, per-zone display rows.

  Input: `[%RevealedCard{}]` from `Scry2.Matches.revealed_cards/1`.

  Output: `[seat_group()]` ordered local first, opponent second, others
  in seat-id order.
  """
  @spec group_by_seat_and_zone([RevealedCard.t()]) :: [seat_group()]
  def group_by_seat_and_zone([]), do: []

  def group_by_seat_and_zone(rows) when is_list(rows) do
    rows
    |> Enum.group_by(& &1.seat_id)
    |> Enum.map(fn {seat_id, seat_rows} ->
      # find_value/2 would return nil for an all-false seat (the opponent),
      # so find the first NON-NIL value rather than the first truthy one.
      is_local = seat_rows |> Enum.map(& &1.is_local) |> Enum.find(&(not is_nil(&1)))

      %{
        seat_id: seat_id,
        is_local: is_local,
        label: seat_label(seat_id, is_local),
        zones: build_zones(seat_rows)
      }
    end)
    |> Enum.reject(&(&1.zones == []))
    |> Enum.sort_by(&seat_sort_key/1)
  end

  @doc """
  Unique arena_ids across every revealed row, regardless of seat or
  zone. The set of card images the match detail page needs cached.
  """
  @spec revealed_arena_ids([RevealedCard.t()]) :: [integer()]
  def revealed_arena_ids(rows) when is_list(rows) do
    rows |> Enum.map(& &1.arena_id) |> Enum.uniq()
  end

  @doc """
  Name for a seat, from its resolved role rather than its number.

  GRE seat ids are per-match numbers and the local player alternates
  seats between matches — seat 1 is the local player in only about 75%
  of real matches — so the number alone cannot say "You". `is_local`
  comes from the domain event log; when it is `nil` (the local seat was
  never resolved for that match) the seat number is shown rather than
  guessing. See ADR-047.
  """
  @spec seat_label(integer(), boolean() | nil) :: String.t()
  def seat_label(_seat_id, true), do: "You"
  def seat_label(_seat_id, false), do: "Opponent"
  def seat_label(seat_id, _unknown) when is_integer(seat_id), do: "Seat #{seat_id}"

  @doc """
  Display name for a semantic zone slug. An unresolved zone (one MTGA
  described with a type we have no mapping for) is titlecased rather than
  hidden, so a new zone is visible in the UI instead of silently dropped.
  """
  @spec zone_label(String.t() | nil) :: String.t()
  def zone_label(nil), do: "Unknown zone"

  def zone_label(zone) when is_binary(zone) do
    case zone do
      "battlefield" -> "Battlefield"
      "hand" -> "Hand"
      "graveyard" -> "Graveyard"
      "exile" -> "Exile"
      "stack" -> "Stack"
      "library" -> "Library"
      "command" -> "Command"
      "sideboard" -> "Sideboard"
      "revealed" -> "Revealed"
      other -> other |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp build_zones(rows) do
    rows
    |> Enum.group_by(& &1.current_zone)
    |> Enum.map(fn {zone, zone_rows} ->
      %{
        zone: zone,
        label: zone_label(zone),
        arena_ids: zone_rows |> Enum.sort_by(& &1.arena_id) |> Enum.map(& &1.arena_id)
      }
    end)
    |> Enum.reject(&(&1.arena_ids == []))
    |> Enum.sort_by(&zone_sort_key/1)
  end

  defp zone_sort_key(%{zone: zone}) do
    case Enum.find_index(@zone_order, &(&1 == zone)) do
      nil -> {1, to_string(zone)}
      index -> {0, index}
    end
  end

  # Local player first, opponent second, unresolved seats after — by role,
  # never by seat number (which does not mean what it used to; see
  # seat_label/2).
  defp seat_sort_key(%{is_local: true}), do: {0, 0}
  defp seat_sort_key(%{is_local: false}), do: {0, 1}
  defp seat_sort_key(%{seat_id: other}), do: {1, other}
end
