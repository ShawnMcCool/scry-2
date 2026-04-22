defmodule Scry2.Collection.Mem.Nif do
  @moduledoc """
  Rustler NIF bridge to the native memory-reader crate.

  Implementation of the `Scry2.Collection.Mem` behaviour lands in later
  phases of ADR 034. Phase 1 only exposes `ping/0` so the NIF build and
  load path can be verified end-to-end.
  """

  use Rustler, otp_app: :scry_2, crate: "scry2_collection_reader"

  @doc "Returns `:pong` to confirm the NIF image compiled and loaded."
  @spec ping() :: :pong
  def ping, do: :erlang.nif_error(:nif_not_loaded)
end
