defmodule Scry2.Buildability.Assessment do
  @moduledoc """
  One card list weighed against the collection — the value every deck
  surface renders: the section-level `result` (status, wildcard cost,
  shortfall), the per-card `main_rows`/`side_rows`, and the wildcard
  balances the cost was measured against.

  `collection_known?` is false when there is no collection snapshot at
  all. Every row then reads as fully missing, which is *unknown*, not
  fact — pages must not annotate ownership in that case.
  """

  alias Scry2.Buildability.CardRow
  alias Scry2.Buildability.CollectionPosition
  alias Scry2.Buildability.Result

  @enforce_keys [:result, :main_rows, :side_rows, :wildcards, :collection_known?]
  defstruct [:result, :main_rows, :side_rows, :wildcards, :collection_known?]

  @type t :: %__MODULE__{
          result: Result.t(),
          main_rows: [CardRow.t()],
          side_rows: [CardRow.t()],
          wildcards: CollectionPosition.wildcard_map(),
          collection_known?: boolean()
        }

  @doc "Every row, maindeck and sideboard, indexed by arena_id for rendering."
  @spec rows_by_arena_id(t()) :: %{integer() => CardRow.t()}
  def rows_by_arena_id(%__MODULE__{main_rows: main_rows, side_rows: side_rows}) do
    CardRow.index(main_rows ++ side_rows)
  end

  @doc "Total copies the player is short across the maindeck and sideboard."
  @spec missing_copies(t()) :: non_neg_integer()
  def missing_copies(%__MODULE__{result: result}) do
    result.maindeck.missing_copies + result.sideboard.missing_copies
  end

  @doc "True when the list needs no wildcards at all — maindeck and sideboard both fully owned."
  @spec fully_owned?(t()) :: boolean()
  def fully_owned?(%__MODULE__{} = assessment), do: missing_copies(assessment) == 0
end
