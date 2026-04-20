defmodule Scry2.SelfUpdate.ApplyLock do
  @moduledoc """
  On-disk coordination between the Elixir self-updater and the Go tray
  watchdog. While an apply is in progress, the lock file signals the
  watchdog to skip its restart attempts — the installer will tear down
  and restart the backend itself.

  Lock file contents (JSON, single line):

      {"pid": 12345, "version": "0.15.0", "phase": "preparing",
       "started_at": "2026-04-20T18:03:11Z"}

  Lifecycle:
    - `acquire/2` — write lock on apply start
    - `update_phase/2` — record state transitions (preparing → ...)
    - `release/1` — remove lock on clean finish
    - `clear_if_stale!/2` — boot-time cleanup of abandoned locks
  """

  require Scry2.Log, as: Log

  defstruct [:pid, :version, :phase, :started_at]

  @type t :: %__MODULE__{
          pid: pos_integer(),
          version: String.t(),
          phase: String.t(),
          started_at: DateTime.t()
        }

  @spec acquire(Path.t(), [{:version, String.t()}]) :: :ok | {:error, term()}
  def acquire(path, opts) do
    version = Keyword.fetch!(opts, :version)

    payload = %{
      "pid" => System.pid() |> to_string() |> String.to_integer(),
      "version" => version,
      "phase" => "preparing",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, Jason.encode!(payload)) do
      :ok ->
        Log.info(:system, fn -> "apply lock acquired: version=#{version} path=#{path}" end)
        :ok

      error ->
        error
    end
  end

  @spec update_phase(Path.t(), String.t()) :: :ok | {:error, :lock_missing | term()}
  def update_phase(path, phase) when is_binary(phase) do
    case File.read(path) do
      {:error, :enoent} ->
        Log.error(:system, "apply lock missing during phase=#{phase}: #{path}")
        {:error, :lock_missing}

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            updated = Map.put(decoded, "phase", phase)
            File.write(path, Jason.encode!(updated))

          {:error, reason} ->
            {:error, {:decode, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec release(Path.t()) :: :ok
  def release(path) do
    _ = File.rm(path)
    :ok
  end

  @spec read(Path.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:error, :enoent} ->
        :none

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            {:ok,
             %__MODULE__{
               pid: decoded["pid"],
               version: decoded["version"],
               phase: decoded["phase"],
               started_at: parse_datetime(decoded["started_at"])
             }}

          {:error, reason} ->
            {:error, {:decode, reason}}
        end

      other ->
        other
    end
  end

  @spec stale?(t(), non_neg_integer()) :: boolean()
  def stale?(%__MODULE__{started_at: %DateTime{} = started_at}, max_age_seconds) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) >= max_age_seconds
  end

  def stale?(_, _), do: true

  @spec clear_if_stale!(Path.t(), non_neg_integer()) :: :not_stale | :cleared | :absent
  def clear_if_stale!(path, max_age_seconds) do
    case read(path) do
      :none ->
        :absent

      {:ok, lock} ->
        if stale?(lock, max_age_seconds) do
          :ok = release(path)
          Log.info(:system, fn -> "apply lock cleared (stale): path=#{path}" end)
          :cleared
        else
          :not_stale
        end

      {:error, reason} ->
        # Corrupt lock — nuke it.
        :ok = release(path)

        Log.warning(:system, fn ->
          "apply lock cleared (corrupt): path=#{path} reason=#{inspect(reason)}"
        end)

        :cleared
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
