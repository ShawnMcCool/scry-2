defmodule Scry2.Uplink.Transport.Http do
  @moduledoc """
  HTTP implementation of `Scry2.Uplink.Transport` (client/server split, ADR-042
  Phase 2). POSTs a batch of wire events to the server ingest endpoint over
  HTTPS with a bearer token.

  Config keys:
    * `:url` — the ingest endpoint URL.
    * `:token` — bearer token issued to this client.
    * `:req_options` — optional keyword list merged into the `Req` request
      (used by tests to inject `plug: {Req.Test, _}`).

  Returns `:ok` on any 2xx (the whole batch was accepted — the Sender then
  advances its cursor), `{:error, {:http_status, status}}` on a non-2xx, and
  `{:error, reason}` on a transport failure — both leave the cursor unadvanced
  so the batch retries.
  """
  @behaviour Scry2.Uplink.Transport

  @impl true
  def send_batch(%{url: url, token: token} = config, wire_events) when is_list(wire_events) do
    req_options = Map.get(config, :req_options, [])

    options =
      [json: %{"events" => wire_events}, auth: {:bearer, token}]
      |> Keyword.merge(req_options)

    case Req.post(url, options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
