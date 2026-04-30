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
