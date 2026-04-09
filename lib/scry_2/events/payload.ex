defmodule Scry2.Events.Payload do
  @moduledoc """
  Shared helpers for deserializing domain event payloads.
  """

  @doc "Parse an ISO 8601 datetime string into a `DateTime`."
  def parse_datetime(nil), do: nil

  def parse_datetime(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc "Convert string keys of a map to integers."
  def integer_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_integer(k), v} end)
  end
end
