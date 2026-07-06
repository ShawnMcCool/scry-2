defmodule Scry2.Uplink.Transport do
  @moduledoc """
  Behaviour for shipping a batch of wire events to the server ingest API
  (client/server split, ADR-042 Phase 2).

  Injected into `Scry2.Uplink.Sender` at start, so the concrete transport
  (real HTTP, a stub, a null sink) is a deployment/test choice and the
  Sender's batching + cursor logic stays transport-agnostic. The HTTP
  implementation and the server endpoint it targets arrive in Phase 2b-2.

  A `:ok` return means the whole batch was durably accepted (the Sender then
  advances the uplink cursor). Any `{:error, reason}` leaves the cursor where
  it is, so the batch is retried on the next flush (at-least-once; the server
  deduplicates by `upload_key`).
  """

  @callback send_batch(config :: map(), wire_events :: [map()]) :: :ok | {:error, term()}
end
