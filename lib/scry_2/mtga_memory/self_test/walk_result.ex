defmodule Scry2.MtgaMemory.SelfTest.WalkResult do
  @moduledoc """
  One walk's outcome in a reader self-test.

  - `outcome` — `:ok` (returned data), `:empty` (worked but nothing to
    read right now), or `:error` (failed).
  - `reason` — raw error term for `:error` (used for classification),
    nil otherwise.
  - `reason_text` — player-language translation of `reason` for display.
  """

  @type outcome :: :ok | :empty | :error

  @type t :: %__MODULE__{
          walk: atom(),
          outcome: outcome(),
          reason: term() | nil,
          reason_text: String.t() | nil,
          elapsed_ms: non_neg_integer()
        }

  @enforce_keys [:walk, :outcome]
  defstruct [:walk, :outcome, :reason, :reason_text, elapsed_ms: 0]
end
