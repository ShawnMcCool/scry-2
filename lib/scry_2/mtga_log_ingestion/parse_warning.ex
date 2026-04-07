defmodule Scry2.MtgaLogIngestion.ParseWarning do
  @moduledoc """
  Structured warning emitted by `ExtractEventsFromLog` when something
  unexpected happens during parsing. Pure data — the impure caller
  (Watcher) decides how to log or surface these.

  See ADR-023 (structured warnings from pure pipeline stages).
  """

  @type category :: :json_decode_failed | :timestamp_parse_failed

  @type t :: %__MODULE__{
          category: category(),
          file_offset: non_neg_integer(),
          detail: String.t()
        }

  @enforce_keys [:category, :file_offset, :detail]
  defstruct [:category, :file_offset, :detail]
end
