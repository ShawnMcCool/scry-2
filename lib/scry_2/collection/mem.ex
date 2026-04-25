defmodule Scry2.Collection.Mem do
  @moduledoc """
  Behaviour for the three low-level process-memory primitives used by
  `Scry2.Collection.Reader`.

  The walker and scanner in `Reader` are pure Elixir; everything that
  crosses the OS boundary goes through exactly these three callbacks,
  which keeps the Rust NIF surface minimal (ADR 034).

  Two implementations:

    * `Scry2.Collection.Mem.Nif` — production; dispatches into the
      `scry2_collection_reader` Rust crate.
    * `Scry2.Collection.Mem.TestBackend` — in-memory fixture; used in
      unit tests so `Reader` can be exercised with synthetic layouts.

  Configured via

      config :scry_2, Scry2.Collection, mem: <module>

  and resolved at call-time through `impl/0`.
  """

  @typedoc "A process identifier as seen by the host OS (pid_t / DWORD)."
  @type pid_int :: non_neg_integer()

  @typedoc """
  One mapped memory region in the target process.

  Mirrors the useful columns of `/proc/<pid>/maps` on Linux and the
  output of `VirtualQueryEx` on Windows.
  """
  @type map_entry :: %{
          required(:start) => non_neg_integer(),
          required(:end_addr) => non_neg_integer(),
          required(:perms) => String.t(),
          required(:path) => String.t() | nil
        }

  @typedoc """
  Enough to identify a live process for MTGA discovery purposes.

  `:name` is the short executable name (e.g. `"MTGA"`); `:cmdline` is
  the full command line, whitespace-normalised.
  """
  @type process_info :: %{
          required(:pid) => pid_int(),
          required(:name) => String.t(),
          required(:cmdline) => String.t()
        }

  @doc "Read `size` bytes at virtual address `addr` in process `pid`."
  @callback read_bytes(pid_int(), non_neg_integer(), non_neg_integer()) ::
              {:ok, binary()} | {:error, atom()}

  @doc "Enumerate mapped memory regions of process `pid`."
  @callback list_maps(pid_int()) :: {:ok, [map_entry()]} | {:error, atom()}

  @doc """
  Return the pid of the first process for which `predicate` returns true.
  """
  @callback find_process((process_info() -> boolean())) ::
              {:ok, pid_int()} | {:error, atom()}

  @typedoc """
  Walker snapshot returned by `walk_collection/1` — the data the
  Rust walker harvests in one pass through MTGA's Mono runtime.
  Matches the contract in ADR 034 Revision 2026-04-25.
  """
  @type walker_snapshot :: %{
          required(:cards) => [{integer(), integer()}],
          required(:wildcards) => %{
            required(:common) => integer(),
            required(:uncommon) => integer(),
            required(:rare) => integer(),
            required(:mythic) => integer()
          },
          required(:gold) => integer(),
          required(:gems) => integer(),
          required(:vault_progress) => float(),
          required(:build_hint) => String.t() | nil,
          required(:reader_version) => String.t()
        }

  @doc """
  Walk MTGA's process memory and return the parsed collection +
  inventory in one shot.

  Implementations should propagate any walker-internal failure as
  `{:error, atom() | tuple()}`. The Reader uses any error as a
  signal to fall back to the structural-scan path.
  """
  @callback walk_collection(pid_int()) :: {:ok, walker_snapshot()} | {:error, term()}

  @doc """
  Returns the configured Mem backend module.

  Set via `config :scry_2, Scry2.Collection, mem: <module>`. Defaults
  to `Scry2.Collection.Mem.Nif` in dev/prod and
  `Scry2.Collection.Mem.TestBackend` in test.
  """
  @spec impl() :: module()
  def impl do
    :scry_2
    |> Application.get_env(Scry2.Collection, [])
    |> Keyword.fetch!(:mem)
  end
end
