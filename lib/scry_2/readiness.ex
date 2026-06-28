defmodule Scry2.Readiness do
  @moduledoc """
  Lightweight readiness probe for the HTTP `/health` endpoint and the
  `scripts/healthcheck` script.

  Reports two things that distinguish "the process is up" from "the app is
  actually ready to serve": database connectivity and whether all migrations
  have been applied. The migration check is the important one — a restart that
  brings the web server up before `mix ecto.migrate` finishes would otherwise
  look healthy while every data page 500s. Here it reports `pending > 0`.

  Pure read-only checks; safe to call on every probe.
  """
  alias Scry2.Repo

  @type migration_status :: %{pending: non_neg_integer() | nil, up_to_date: boolean()}
  @type t :: %{
          status: :ok | :error,
          database: :ok | :error,
          migrations: migration_status()
        }

  @spec check() :: t()
  def check do
    database = database_status()
    migrations = migration_status()
    overall = if database == :ok and migrations.up_to_date, do: :ok, else: :error

    %{status: overall, database: database, migrations: migrations}
  end

  defp database_status do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> :ok
      _other -> :error
    end
  rescue
    _error -> :error
  end

  defp migration_status do
    pending =
      Repo
      |> Ecto.Migrator.migrations()
      |> Enum.count(fn {status, _version, _name} -> status == :down end)

    %{pending: pending, up_to_date: pending == 0}
  rescue
    _error -> %{pending: nil, up_to_date: false}
  end
end
