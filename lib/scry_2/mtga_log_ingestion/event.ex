defmodule Scry2.MtgaLogIngestion.Event do
  @moduledoc """
  In-memory struct representing a parsed MTGA log event.

  Produced by `Scry2.MtgaLogIngestion.ExtractEventsFromLog`. Not to be confused with
  `Scry2.MtgaLogIngestion.EventRecord`, which is the Ecto schema for the
  persisted `mtga_logs_events` table.

  Fields:
    * `:type` — the MTGA event type string (e.g. `"EventMatchCreated"`)
    * `:mtga_timestamp` — timestamp extracted from the log line header
    * `:payload` — decoded JSON payload as a map
    * `:raw_json` — the original JSON string, stored verbatim for ADR-015
    * `:file_offset` — byte offset in the source file where this event began
    * `:source_file` — absolute path of the source file
  """

  @enforce_keys [:type, :raw_json, :file_offset, :source_file]
  defstruct [
    :type,
    :mtga_timestamp,
    :payload,
    :raw_json,
    :file_offset,
    :source_file
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          mtga_timestamp: DateTime.t() | nil,
          payload: map() | nil,
          raw_json: String.t(),
          file_offset: non_neg_integer(),
          source_file: String.t()
        }
end
