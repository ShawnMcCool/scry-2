defmodule Scry2.Events.TranslationWarning do
  @moduledoc """
  Structured warning emitted by `IdentifyDomainEvents` when a handled
  MTGA event type fails to produce domain events due to malformed data.
  Pure data — the impure caller (IngestRawEvents) decides how to log or
  surface these.

  See ADR-023 (structured warnings from pure pipeline stages).
  """

  @type category :: :json_decode_failed | :payload_extraction_failed

  @type t :: %__MODULE__{
          category: category(),
          raw_event_id: integer() | nil,
          event_type: String.t(),
          detail: String.t()
        }

  @enforce_keys [:category, :event_type, :detail]
  defstruct [:category, :raw_event_id, :event_type, :detail]
end
