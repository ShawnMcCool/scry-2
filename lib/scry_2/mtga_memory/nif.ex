defmodule Scry2.MtgaMemory.Nif do
  @moduledoc """
  Rustler NIF bridge implementing `Scry2.MtgaMemory`.

  The NIF crate exposes four primitives (`ping`, `read_bytes`,
  `list_maps_nif`, `list_processes_nif`); this module wraps them into
  the behaviour's public shape — returning maps instead of tuples and
  performing the `find_process/1` predicate match in Elixir so the
  Rust surface stays data-only.

  On non-Linux platforms today every primitive returns
  `{:error, :not_implemented}`; see ADR 034 for the roadmap.
  """

  @behaviour Scry2.MtgaMemory

  use Rustler, otp_app: :scry_2, crate: "scry2_collection_reader"

  @doc "Heartbeat — returns `:pong` once the NIF image is loaded."
  @spec ping() :: :pong
  def ping, do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def read_bytes(_pid, _addr, _size), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def list_maps(pid) do
    case list_maps_nif(pid) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, &row_to_map_entry/1)}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def find_process(predicate) when is_function(predicate, 1) do
    case list_processes_nif() do
      {:ok, rows} ->
        rows
        |> Enum.find_value(fn {pid, name, cmdline} ->
          info = %{pid: pid, name: name, cmdline: cmdline}
          if predicate.(info), do: pid, else: nil
        end)
        |> case do
          nil -> {:error, :not_found}
          pid -> {:ok, pid}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def walk_collection(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def walk_match_info(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def walk_match_board(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def walk_mastery(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec walker_debug_classes_matching(non_neg_integer(), String.t()) ::
          {:ok, [{String.t(), String.t(), non_neg_integer()}]} | {:error, atom()}
  def walker_debug_classes_matching(_pid, _needle), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec walker_debug_list_assemblies(non_neg_integer()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, atom()}
  def walker_debug_list_assemblies(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec walker_debug_class_fields(non_neg_integer(), String.t()) ::
          {:ok, [{String.t(), String.t(), integer(), boolean()}]} | {:error, atom()}
  def walker_debug_class_fields(_pid, _class_name), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  `walk_match_info` plus per-call read-budget stats. Returns
  `{result, %{reads_used: N, budget: B}}` so callers can monitor how
  close each walk is to the read-budget ceiling. Used by the Settings
  → Memory reading "Run diagnostic capture now" button and by any
  ad-hoc instrumentation we want to add without disturbing the
  production walker call shape.
  """
  @spec walker_debug_walk_match_info_with_stats(non_neg_integer()) ::
          {{:ok, map() | nil} | {:error, term()},
           %{reads_used: non_neg_integer(), budget: non_neg_integer()}}
  def walker_debug_walk_match_info_with_stats(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  `walk_match_board` plus per-call read-budget stats. Same shape as
  `walker_debug_walk_match_info_with_stats/1`.
  """
  @spec walker_debug_walk_match_board_with_stats(non_neg_integer()) ::
          {{:ok, map() | nil} | {:error, term()},
           %{reads_used: non_neg_integer(), budget: non_neg_integer()}}
  def walker_debug_walk_match_board_with_stats(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Snapshot the discovery cache state. Returns
  `[{pid, "filled,slots,csv"}]` — one tuple per cached pid, with a
  comma-separated list of which anchors are currently held. Used by
  the admin memory diagnostics page.
  """
  @spec walker_debug_cache_snapshot() :: [{non_neg_integer(), String.t()}]
  def walker_debug_cache_snapshot, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Drop the discovery cache for `pid`. Forces full re-discovery on the
  next walker call against that pid. For the admin page's "force
  re-discovery" button.
  """
  @spec walker_debug_cache_invalidate(non_neg_integer()) :: :ok
  def walker_debug_cache_invalidate(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Drop the entire discovery cache (every pid). For the admin page's
  "clear all" button and for tests that need a clean slate.
  """
  @spec walker_debug_cache_clear() :: :ok
  def walker_debug_cache_clear, do: :erlang.nif_error(:nif_not_loaded)

  # --- raw NIF declarations ---

  @doc false
  def list_maps_nif(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def list_processes_nif, do: :erlang.nif_error(:nif_not_loaded)

  # --- row shape helpers ---

  defp row_to_map_entry({start, end_addr, perms, path}) do
    %{start: start, end_addr: end_addr, perms: perms, path: path}
  end
end
