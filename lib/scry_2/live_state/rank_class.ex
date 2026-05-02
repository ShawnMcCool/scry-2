defmodule Scry2.LiveState.RankClass do
  @moduledoc """
  Translates MTGA's `RankingClass` enum (i32 read from
  `MatchManager.PlayerInfo.RankingClass`) to its domain-string name.

  Enum values per `.claude/skills/mono-memory-reader/SKILL.md`:
  `[None, Bronze, Silver, Gold, Platinum, Diamond, Mythic]` (index 0..6).

  Returns `nil` for `nil` input or out-of-range integers — the latter
  indicates a walker reading from an unfamiliar build; we'd rather
  drop the field than persist garbage.
  """

  @spec name(integer() | nil) :: String.t() | nil
  def name(nil), do: nil
  def name(0), do: "None"
  def name(1), do: "Bronze"
  def name(2), do: "Silver"
  def name(3), do: "Gold"
  def name(4), do: "Platinum"
  def name(5), do: "Diamond"
  def name(6), do: "Mythic"
  def name(_other), do: nil
end
