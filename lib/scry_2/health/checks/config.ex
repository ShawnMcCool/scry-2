defmodule Scry2.Health.Checks.Config do
  @moduledoc """
  Pure configuration-sanity checks.

    * Is `mtga_self_user_id` set? (optional, but improves match accuracy)
    * Is the SQLite database writable?
    * Do the data and cache directories exist?

  Functions accept their inputs as arguments. File-system checks (writable,
  dirs exist) take the paths directly and touch disk — still async-safe
  because each test can pass in unique temp paths.
  """

  alias Scry2.Health.Check

  @doc """
  Reports whether `mtga_self_user_id` is configured.

  It's optional — when `nil`, the pipeline falls back to assuming
  `systemSeatId == 1` is the player. That's almost always correct,
  but it can be wrong in replay tools or shared accounts. We report
  `:warning`, not `:error`, because the fallback is robust.
  """
  @spec self_user_id_configured(String.t() | nil) :: Check.t()
  def self_user_id_configured(nil) do
    Check.new(
      id: :self_user_id_configured,
      category: :config,
      name: "Self user ID set",
      status: :warning,
      summary: "mtga_self_user_id not set — using seat ID fallback",
      detail:
        "Scry2 will assume the player is always in seat 1. This is correct " <>
          "for almost all MTGA matches but can be wrong in exotic cases. " <>
          "Set [mtga_logs] self_user_id in config.toml to be explicit."
    )
  end

  def self_user_id_configured(user_id) when is_binary(user_id) do
    Check.new(
      id: :self_user_id_configured,
      category: :config,
      name: "Self user ID set",
      status: :ok,
      summary: "Configured"
    )
  end

  @doc """
  Reports whether the database file is writable.

  Uses a stat + parent-writable probe rather than an insert-and-rollback.
  This is cheap enough to run on every health-screen render without
  touching the connection pool.
  """
  @spec database_writable(String.t() | nil) :: Check.t()
  def database_writable(nil) do
    Check.new(
      id: :database_writable,
      category: :config,
      name: "Database writable",
      status: :error,
      summary: "No database path configured"
    )
  end

  def database_writable(path) when is_binary(path) do
    dir = Path.dirname(path)

    with {:ok, %File.Stat{access: db_access}} <- File.stat(path),
         true <- db_access in [:read_write, :write],
         {:ok, %File.Stat{access: dir_access}} <- File.stat(dir),
         true <- dir_access in [:read_write, :write] do
      Check.new(
        id: :database_writable,
        category: :config,
        name: "Database writable",
        status: :ok,
        summary: path
      )
    else
      _ ->
        Check.new(
          id: :database_writable,
          category: :config,
          name: "Database writable",
          status: :error,
          summary: "Database file or directory is not writable",
          detail: "Checked path: #{path}"
        )
    end
  end

  @doc """
  Reports whether the data and cache directories exist and are writable.

  Takes a keyword list of `[name: path]` pairs; returns a single
  `%Check{}` describing the overall state.
  """
  @spec data_dirs_exist([{atom(), String.t() | nil}]) :: Check.t()
  def data_dirs_exist(dirs) when is_list(dirs) do
    results =
      Enum.map(dirs, fn {name, path} ->
        {name, path, dir_status(path)}
      end)

    missing = Enum.filter(results, fn {_name, _path, status} -> status != :ok end)

    case missing do
      [] ->
        Check.new(
          id: :data_dirs_exist,
          category: :config,
          name: "Data directories ready",
          status: :ok,
          summary: "#{length(results)} directories present and writable"
        )

      missing ->
        detail =
          Enum.map_join(missing, "\n", fn {name, path, status} ->
            "#{name}: #{path || "(unset)"} — #{status}"
          end)

        Check.new(
          id: :data_dirs_exist,
          category: :config,
          name: "Data directories ready",
          status: :error,
          summary: "#{length(missing)} data directories not ready",
          detail: detail
        )
    end
  end

  defp dir_status(nil), do: :unset

  defp dir_status(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write] ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        :not_writable

      {:ok, _} ->
        :not_a_directory

      {:error, reason} ->
        reason
    end
  end
end
