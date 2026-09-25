defmodule Scry2.Events.IdentifyDomainEvents.ZoneTable do
  @moduledoc """
  The anti-corruption layer's one representation of MTGA's per-game zone
  table: which GRE `zoneId` means which zone, who owns it, and who can
  see it.

  ## Why this exists

  GRE zone ids are per-game instance ids — zone `31` is "the hand" only
  within one game. The semantics live in the `zones` array of a
  `GameStateMessage`:

      %{"zoneId" => 31, "type" => "ZoneType_Hand",
        "visibility" => "Visibility_Private", "ownerSeatId" => 1,
        "objectInstanceIds" => [401, 402]}

  Before ADR-047 the ACL carried this as two ad-hoc shapes — a
  `zone_owners` map and `GREProtocol.zone_name/1`, which stringified an
  id to `"zone_31"` and discarded the type entirely. Both are replaced
  by this module.

  ## Accumulation

  Only some `GameStateMessage`s carry a `zones` array (roughly one in
  three raw events, measured 2026-09-25). A batch must therefore
  accumulate the table with `merge/2` rather than rebuild it per
  message, or zone semantics vanish on every message that omits it.

  See [ADR-047](../../../decisions/architecture/2026-09-25-047-revealed-cards-from-domain-events.md).
  """

  @enforce_keys [:zones]
  defstruct zones: %{}

  @typedoc """
  A resolved zone type. Unrecognised MTGA zone types are carried through
  as their raw `"ZoneType_*"` string so a new zone is visible in the data
  rather than silently dropped.
  """
  @type zone_type ::
          :battlefield
          | :hand
          | :graveyard
          | :exile
          | :library
          | :stack
          | :limbo
          | :revealed
          | :pending
          | :command
          | :sideboard
          | :suppressed
          | String.t()

  @type zone :: %{
          type: zone_type() | nil,
          visibility: String.t() | nil,
          owner_seat_id: integer() | nil
        }

  @type t :: %__MODULE__{zones: %{integer() => zone()}}

  # The twelve ZoneType_* values observed across the full event history.
  @zone_types %{
    "ZoneType_Battlefield" => :battlefield,
    "ZoneType_Hand" => :hand,
    "ZoneType_Graveyard" => :graveyard,
    "ZoneType_Exile" => :exile,
    "ZoneType_Library" => :library,
    "ZoneType_Stack" => :stack,
    "ZoneType_Limbo" => :limbo,
    "ZoneType_Revealed" => :revealed,
    "ZoneType_Pending" => :pending,
    "ZoneType_Command" => :command,
    "ZoneType_Sideboard" => :sideboard,
    "ZoneType_Suppressed" => :suppressed
  }

  @doc "An empty zone table."
  @spec new() :: t()
  def new, do: %__MODULE__{zones: %{}}

  @doc """
  Build a zone table from one `gameStateMessage` map. Returns an empty
  table when the message carries no `zones` array.
  """
  @spec from_game_state(map() | nil) :: t()
  def from_game_state(%{"zones" => zones}) when is_list(zones) do
    %__MODULE__{zones: Map.new(zones, &{&1["zoneId"], to_zone(&1)})}
  end

  def from_game_state(_), do: new()

  @doc """
  Accumulate `later` on top of `earlier`. Zones present in both take
  their value from `later`; zones only in `earlier` survive.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{zones: earlier}, %__MODULE__{zones: later}) do
    %__MODULE__{zones: Map.merge(earlier, later)}
  end

  @doc "The zone type for `zone_id`, or `nil` when the zone is unknown."
  @spec type(t(), integer() | nil) :: zone_type() | nil
  def type(%__MODULE__{} = table, zone_id), do: get_in_zone(table, zone_id, :type)

  @doc """
  The seat that owns `zone_id`, or `nil` for shared zones (battlefield,
  stack) and unknown ids.
  """
  @spec owner_seat(t(), integer() | nil) :: integer() | nil
  def owner_seat(%__MODULE__{} = table, zone_id),
    do: get_in_zone(table, zone_id, :owner_seat_id)

  @doc """
  The display label for `zone_id` — the semantic zone slug
  (`"battlefield"`, `"hand"`, …) when the zone is known.

  An unknown zone falls back to `"zone_<id>"`, the pre-ADR-047 form, so a
  transition referencing a zone the table has not seen keeps its id
  instead of being discarded.
  """
  @spec label(t(), integer() | nil) :: String.t() | nil
  def label(_table, nil), do: nil

  def label(%__MODULE__{} = table, zone_id) do
    case type(table, zone_id) do
      nil when is_integer(zone_id) and zone_id > 0 -> "zone_#{zone_id}"
      nil -> nil
      type when is_atom(type) -> Atom.to_string(type)
      wire -> wire
    end
  end

  @doc "The GRE visibility string for `zone_id`, or `nil` when unknown."
  @spec visibility(t(), integer() | nil) :: String.t() | nil
  def visibility(%__MODULE__{} = table, zone_id),
    do: get_in_zone(table, zone_id, :visibility)

  defp get_in_zone(%__MODULE__{zones: zones}, zone_id, key) do
    case Map.get(zones, zone_id) do
      nil -> nil
      zone -> Map.get(zone, key)
    end
  end

  defp to_zone(zone) do
    %{
      type: resolve_type(zone["type"]),
      visibility: zone["visibility"],
      owner_seat_id: zone["ownerSeatId"]
    }
  end

  defp resolve_type(nil), do: nil
  defp resolve_type(wire), do: Map.get(@zone_types, wire, wire)
end
