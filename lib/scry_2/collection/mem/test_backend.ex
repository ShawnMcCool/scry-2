defmodule Scry2.Collection.Mem.TestBackend do
  @moduledoc """
  In-memory fixture backend for `Scry2.Collection.Mem`.

  Each test sets its own fixture via `set_fixture/1`; state lives in
  the calling process's dictionary so `async: true` stays safe across
  concurrent tests (ADR 034 phase 2).

  ## Fixture shape

      %{
        memory:    [{non_neg_integer(), binary()}, ...],
        maps:      [Scry2.Collection.Mem.map_entry(), ...],
        processes: [Scry2.Collection.Mem.process_info(), ...]
      }

  All keys are optional. Omitted keys behave as "no data for that
  primitive" — e.g. `read_bytes/3` against a fixture without `:memory`
  returns `{:error, :unmapped}`.
  """

  @behaviour Scry2.Collection.Mem

  @fixture_key {__MODULE__, :fixture}

  @type memory_region :: {non_neg_integer(), binary()}

  @type fixture :: %{
          optional(:memory) => [memory_region()],
          optional(:maps) => [Scry2.Collection.Mem.map_entry()],
          optional(:processes) => [Scry2.Collection.Mem.process_info()],
          optional(:walker_snapshot) => Scry2.Collection.Mem.walker_snapshot() | {:error, term()}
        }

  @doc """
  Installs `fixture` on the current process for subsequent Mem callbacks.

  Accepts a keyword list or map so tests can use either syntax.
  """
  @spec set_fixture(fixture() | keyword()) :: :ok
  def set_fixture(fixture) when is_list(fixture) do
    set_fixture(Map.new(fixture))
  end

  def set_fixture(fixture) when is_map(fixture) do
    Process.put(@fixture_key, fixture)
    :ok
  end

  @doc "Removes the per-process fixture. Safe to call when none was set."
  @spec clear_fixture() :: :ok
  def clear_fixture do
    Process.delete(@fixture_key)
    :ok
  end

  @impl true
  def read_bytes(_pid, addr, size) do
    with {:ok, fixture} <- fetch_fixture() do
      regions = Map.get(fixture, :memory, [])
      read_from_regions(regions, addr, size)
    end
  end

  @impl true
  def list_maps(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      {:ok, Map.get(fixture, :maps, [])}
    end
  end

  @impl true
  def find_process(predicate) when is_function(predicate, 1) do
    with {:ok, fixture} <- fetch_fixture() do
      fixture
      |> Map.get(:processes, [])
      |> Enum.find(predicate)
      |> case do
        nil -> {:error, :not_found}
        %{pid: pid} -> {:ok, pid}
      end
    end
  end

  @impl true
  def walk_collection(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :walker_snapshot) do
        :error -> {:error, :no_walker_snapshot}
        {:ok, {:error, _} = err} -> err
        {:ok, snap} -> {:ok, snap}
      end
    end
  end

  defp fetch_fixture do
    case Process.get(@fixture_key) do
      nil -> {:error, :no_fixture}
      fixture -> {:ok, fixture}
    end
  end

  defp read_from_regions([], _addr, _size), do: {:error, :unmapped}

  defp read_from_regions([{region_start, bytes} | rest], addr, size) do
    region_end = region_start + byte_size(bytes)

    cond do
      addr >= region_start and addr + size <= region_end ->
        offset = addr - region_start
        {:ok, binary_part(bytes, offset, size)}

      true ->
        read_from_regions(rest, addr, size)
    end
  end
end
