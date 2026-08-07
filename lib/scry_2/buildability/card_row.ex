defmodule Scry2.Buildability.CardRow do
  @moduledoc """
  One card of a list weighed against the collection: how many copies the
  list wants, how many the player owns (across every printing of the
  name), and how many are missing.

  `free?` marks cards the player can never be short of — basic lands
  today. Their `missing` is always zero, whatever the collection says.
  """

  @enforce_keys [:arena_id, :name, :rarity, :needed, :owned, :missing, :free?]
  defstruct [:arena_id, :name, :rarity, :needed, :owned, :missing, :free?]

  @type t :: %__MODULE__{
          arena_id: integer() | nil,
          name: String.t(),
          rarity: String.t() | nil,
          needed: non_neg_integer(),
          owned: non_neg_integer(),
          missing: non_neg_integer(),
          free?: boolean()
        }

  @doc """
  Indexes rows by `arena_id` for per-card lookup while rendering. Rows
  without a resolved arena_id are skipped — they can't be matched to a
  rendered card.
  """
  @spec index([t()]) :: %{integer() => t()}
  def index(rows) do
    rows
    |> Enum.filter(&is_integer(&1.arena_id))
    |> Map.new(fn row -> {row.arena_id, row} end)
  end
end
