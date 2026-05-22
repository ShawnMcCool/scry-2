defmodule Scry2.MtgaMemory.SelfTest.Report do
  @moduledoc """
  The full result of a reader self-test: process state, the MTGA build +
  reader version it ran against, every walk's `WalkResult`, and the
  derived `Diagnosis`.
  """

  alias Scry2.MtgaMemory.SelfTest.{Diagnosis, WalkResult}

  @type t :: %__MODULE__{
          mtga_running: boolean(),
          pid: non_neg_integer() | nil,
          build_hint: String.t() | nil,
          reader_version: String.t() | nil,
          ran_at: DateTime.t(),
          walks: [WalkResult.t()],
          diagnosis: Diagnosis.t()
        }

  @enforce_keys [:mtga_running, :ran_at, :walks, :diagnosis]
  defstruct [:mtga_running, :pid, :build_hint, :reader_version, :ran_at, :walks, :diagnosis]
end
