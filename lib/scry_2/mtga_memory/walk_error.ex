defmodule Scry2.MtgaMemory.WalkError do
  @moduledoc """
  Translates memory-reader walk failures (the error atoms / tagged
  tuples the Rust NIF returns) into short, player-language phrases, and
  classifies whether a failure happened in the *shared discovery base*
  every walk traverses or in a walk-specific chain.

  The Rust walker's `WalkError` enum
  (`native/scry2_collection_reader/src/walker/run.rs`) crosses the NIF
  boundary as:

    * bare atoms — `:mono_dll_not_found`, `:mono_dll_read_failed`,
      `:root_domain_not_found`, `:chain_failed`
    * tagged tuples — `{:assembly_not_found, name}`,
      `{:class_not_found, name}`, `{:class_read_failed, name}`

  When a new failure mode is added in Rust, add a `translate/1` clause
  here (and, if it lives in the shared discovery base, a
  `shared_chain?/1` clause) — this is the single mapping point used by
  both the build-change banner and the reader self-test.
  """

  @doc """
  Translate a walk failure term into a short player-language phrase.
  Strings pass through unchanged; unknown shapes get a generic message.
  """
  @spec translate(term()) :: String.t()
  def translate(:mono_dll_not_found),
    do: "Couldn't find MTGA's runtime module — the game may not have finished loading yet"

  def translate(:mono_dll_read_failed),
    do: "MTGA's runtime module wouldn't open for reading"

  def translate(:root_domain_not_found),
    do: "Couldn't enter MTGA's runtime — likely an offsets change"

  def translate(:chain_failed),
    do: "Couldn't trace the pointer chain — likely an offsets change"

  def translate({:assembly_not_found, name}) when is_binary(name),
    do: "Couldn't find MTGA's #{name} module"

  def translate({:class_not_found, name}) when is_binary(name),
    do: "MTGA's #{name} data layout has changed"

  def translate({:class_read_failed, name}) when is_binary(name),
    do: "MTGA's #{name} data couldn't be read — likely an offsets change"

  def translate(reason) when is_binary(reason), do: reason

  def translate(_),
    do: "Memory reader hit an unexpected error — see Diagnostics for details"

  @doc """
  True when the failure is in the shared discovery base that every walk
  traverses (Mono DLL location + root-domain entry). When *all* walks
  fail with a shared-chain error, the whole reader is down rather than
  one specific data layout having shifted.
  """
  @spec shared_chain?(term()) :: boolean()
  def shared_chain?(:mono_dll_not_found), do: true
  def shared_chain?(:mono_dll_read_failed), do: true
  def shared_chain?(:root_domain_not_found), do: true
  def shared_chain?(_), do: false
end
