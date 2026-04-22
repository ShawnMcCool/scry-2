defmodule Scry2.Collection.Reader.SelfCheck do
  @moduledoc """
  Validation gates the reader must pass before emitting output.
  The full set in ADR 034 enumerates seven checks (Spike 13) — this
  module implements the subset applicable to the scanner-only path:

    * `discovery_ok?/1` — mono runtime + UnityPlayer both mapped.
    * `access_channel_ok?/3` — MTGA.exe PE "MZ" header is readable.
    * `scan_result_ok?/1` — scan produced enough entries with a
      plausible count distribution and positive arena ids.

  Walker-specific checks (mono prologue, root domain, PAPA class walk)
  land when the walker path is implemented.

  Every failure returns `{:error, {:check, atom | tuple}}` so the caller
  can route it to the Console drawer unchanged.
  """

  alias Scry2.Collection.Mem

  @mono_module_suffix "mono-2.0-bdwgc.dll"
  @unity_player_suffix "UnityPlayer.dll"
  @mtga_exe_suffix "MTGA.exe"
  @default_min_scan_entries 500
  @max_dominant_count_ratio 0.95

  @doc """
  Passes when the target process has both the mono runtime and the
  Unity player DLL mapped — a hard prerequisite for the reader.
  """
  @spec discovery_ok?([Mem.map_entry()]) :: :ok | {:error, {:check, atom()}}
  def discovery_ok?(maps) do
    cond do
      not has_module?(maps, @mono_module_suffix) ->
        {:error, {:check, :missing_mono_module}}

      not has_module?(maps, @unity_player_suffix) ->
        {:error, {:check, :missing_unity_player}}

      true ->
        :ok
    end
  end

  @doc """
  Passes when reading the first two bytes of MTGA.exe's mapped image
  returns the PE "MZ" signature, proving the `read_bytes` channel
  actually reaches the target's memory.
  """
  @spec access_channel_ok?(module(), Mem.pid_int(), [Mem.map_entry()]) ::
          :ok | {:error, {:check, atom() | {atom(), atom()}}}
  def access_channel_ok?(mem, pid, maps) do
    case find_mtga_exe_map(maps) do
      {:ok, %{start: start}} ->
        case mem.read_bytes(pid, start, 2) do
          {:ok, <<0x4D, 0x5A>>} -> :ok
          {:ok, _other} -> {:error, {:check, :not_pe_header}}
          {:error, reason} -> {:error, {:check, {:read_failed, reason}}}
        end

      :error ->
        {:error, {:check, :mtga_exe_not_mapped}}
    end
  end

  @doc """
  Passes when the scanner finding has enough entries to be trustworthy,
  at least moderate count variance, and no bogus arena ids.

  Used for the fallback-scan path; the walker path will supply a
  stricter equivalent (count == dict `_count`, entries vtable non-null).
  """
  @spec scan_result_ok?(%{:entries => [term()], optional(atom()) => any()}, keyword()) ::
          :ok | {:error, {:check, atom() | tuple()}}
  def scan_result_ok?(finding, opts \\ [])

  def scan_result_ok?(%{entries: entries}, opts) do
    min_entries = Keyword.get(opts, :min_scan_entries, @default_min_scan_entries)

    cond do
      length(entries) < min_entries ->
        {:error, {:check, {:scan_result_too_small, length(entries)}}}

      not all_arena_ids_positive?(entries) ->
        {:error, {:check, :non_positive_arena_id}}

      not plausible_count_distribution?(entries) ->
        {:error, {:check, :implausible_count_distribution}}

      true ->
        :ok
    end
  end

  # --- helpers ---

  defp has_module?(maps, suffix) do
    Enum.any?(maps, fn
      %{path: nil} -> false
      %{path: path} when is_binary(path) -> String.ends_with?(path, suffix)
      _ -> false
    end)
  end

  defp find_mtga_exe_map(maps) do
    Enum.find_value(maps, :error, fn
      %{path: path, perms: perms} = entry
      when is_binary(path) ->
        if String.ends_with?(path, @mtga_exe_suffix) and String.starts_with?(perms, "r") do
          {:ok, entry}
        else
          false
        end

      _ ->
        false
    end)
  end

  defp all_arena_ids_positive?(entries) do
    Enum.all?(entries, fn {arena_id, _count} -> arena_id > 0 end)
  end

  defp plausible_count_distribution?(entries) do
    counts = Enum.map(entries, fn {_, count} -> count end)
    dist = Enum.frequencies(counts)
    {_count, freq} = Enum.max_by(dist, fn {_, f} -> f end)
    freq / length(entries) < @max_dominant_count_ratio
  end
end
