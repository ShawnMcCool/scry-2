defmodule Scry2.MtgaMemory.TestBackend do
  @moduledoc """
  In-memory fixture backend for `Scry2.MtgaMemory`.

  Each test sets its own fixture via `set_fixture/1`; state lives in
  the calling process's dictionary so `async: true` stays safe across
  concurrent tests (ADR 034 phase 2).

  ## Fixture shape

      %{
        memory:    [{non_neg_integer(), binary()}, ...],
        maps:      [Scry2.MtgaMemory.map_entry(), ...],
        processes: [Scry2.MtgaMemory.process_info(), ...]
      }

  All keys are optional. Omitted keys behave as "no data for that
  primitive" — e.g. `read_bytes/3` against a fixture without `:memory`
  returns `{:error, :unmapped}`.
  """

  @behaviour Scry2.MtgaMemory

  @fixture_key {__MODULE__, :fixture}

  @type memory_region :: {non_neg_integer(), binary()}

  @type fixture :: %{
          optional(:memory) => [memory_region()],
          optional(:maps) => [Scry2.MtgaMemory.map_entry()],
          optional(:processes) => [Scry2.MtgaMemory.process_info()],
          optional(:walker_snapshot) => Scry2.MtgaMemory.walker_snapshot() | {:error, term()},
          optional(:match_info) => Scry2.MtgaMemory.match_info() | nil | {:error, term()},
          optional(:board_snapshot) => Scry2.MtgaMemory.board_snapshot() | nil | {:error, term()},
          optional(:mastery_info) => Scry2.MtgaMemory.mastery_info() | nil | {:error, term()},
          optional(:event_list) => Scry2.MtgaMemory.event_list() | nil | {:error, term()}
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

  @impl true
  def walk_match_info(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :match_info) do
        :error -> {:error, :no_match_info}
        {:ok, {:error, _} = err} -> err
        {:ok, nil} -> {:ok, nil}
        {:ok, snap} -> {:ok, snap}
      end
    end
  end

  @impl true
  def walk_match_board(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :board_snapshot) do
        :error -> {:error, :no_board_snapshot}
        {:ok, {:error, _} = err} -> err
        {:ok, nil} -> {:ok, nil}
        {:ok, snap} -> {:ok, snap}
      end
    end
  end

  @impl true
  def walk_mastery(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :mastery_info) do
        :error -> {:error, :no_mastery_info}
        {:ok, {:error, _} = err} -> err
        {:ok, nil} -> {:ok, nil}
        {:ok, snap} -> {:ok, snap}
      end
    end
  end

  @impl true
  def walk_events(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :event_list) do
        :error -> {:error, :no_event_list}
        {:ok, {:error, _} = err} -> err
        {:ok, nil} -> {:ok, nil}
        {:ok, snap} -> {:ok, snap}
      end
    end
  end

  @impl true
  def walk_account(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :account_identity) do
        :error -> {:ok, nil}
        {:ok, {:error, _} = err} -> err
        {:ok, nil} -> {:ok, nil}
        {:ok, snap} -> {:ok, snap}
      end
    end
  end

  @impl true
  def walk_cosmetics(_pid) do
    with {:ok, fixture} <- fetch_fixture() do
      case Map.fetch(fixture, :cosmetics_summary) do
        :error -> {:ok, nil}
        {:ok, {:error, _} = err} -> err
        {:ok, nil} -> {:ok, nil}
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
