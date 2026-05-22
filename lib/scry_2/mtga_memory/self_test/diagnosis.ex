defmodule Scry2.MtgaMemory.SelfTest.Diagnosis do
  @moduledoc """
  The overall verdict derived from a set of per-walk results.

  `status` drives the UI tone; `headline` + `detail` are player-language.
  `broken` / `working` list the walk names in each bucket (empty for
  non-`:partial` statuses).
  """

  @type status ::
          :mtga_not_running
          | :healthy
          | :runtime_not_ready
          | :deep_break
          | :partial

  @type t :: %__MODULE__{
          status: status(),
          headline: String.t(),
          detail: String.t(),
          broken: [atom()],
          working: [atom()]
        }

  @enforce_keys [:status, :headline, :detail]
  defstruct [:status, :headline, :detail, broken: [], working: []]
end
