defmodule Scry2.Decks.FormatStats do
  @moduledoc """
  Aggregated win/loss totals for a single match format (BO1 or BO3).

  Used by `Scry2.Decks.list_decks_with_stats/2` and read by the LiveView
  `record_cell` component. `:win_rate` is `nil` when `:total` is zero.
  """

  @enforce_keys [:total, :wins, :losses]
  defstruct [:total, :wins, :losses, :win_rate]

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          wins: non_neg_integer(),
          losses: non_neg_integer(),
          win_rate: float() | nil
        }
end
