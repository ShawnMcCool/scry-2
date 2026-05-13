defmodule Scry2.Insights.Detectors.Numeric do
  @moduledoc """
  Shared numeric coercions for insight detectors.

  Aggregated SQL results arrive as a mix of `nil`, integers, and
  `Decimal` values (depending on whether the column was summed,
  counted, or selected directly). Detectors normalise to plain
  integers before building their measurement payloads.
  """

  @doc """
  Coerce a SQL aggregate result into an integer. Treats `nil` as `0`,
  passes integers through, and converts `Decimal` to integer.
  """
  @spec to_int(nil | integer() | Decimal.t()) :: integer()
  def to_int(nil), do: 0
  def to_int(int) when is_integer(int), do: int
  def to_int(%Decimal{} = d), do: Decimal.to_integer(d)
end
