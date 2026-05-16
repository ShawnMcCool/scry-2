defmodule Scry2.Repo do
  use Ecto.Repo,
    otp_app: :scry_2,
    adapter: Ecto.Adapters.SQLite3

  # Mix.env() resolved at compile time and baked in — Mix is not available
  # at runtime in a release. Gates the TOML-override path so dev and test
  # use the explicit DB from their config files; only prod (which is the
  # one without a config/$env.exs setting a path) reads the user's
  # ~/.config/scry_2/config.toml. Without this gate, `mix ecto.migrate`
  # in dev silently retargets the user's prod DB.
  @compile_mix_env Mix.env()

  @doc """
  Overrides the database path at runtime from the user's TOML config file.

  Runs before the Repo process starts (and before the Config GenServer),
  so it reads the TOML file directly rather than going through Config.

  Only active in prod — dev and test use the database path from their
  config files verbatim.
  """
  @impl true
  def init(_context, config) do
    database_path =
      if @compile_mix_env == :prod do
        read_database_path_from_toml() || config[:database]
      else
        config[:database]
      end

    :ok = ensure_directory(database_path)
    {:ok, Keyword.put(config, :database, database_path)}
  end

  defp read_database_path_from_toml do
    path = Scry2.Config.config_path()

    with {:ok, contents} <- File.read(path),
         {:ok, toml} <- Toml.decode(contents),
         database_path when is_binary(database_path) <-
           get_in(toml, ["database", "path"]) do
      Path.expand(database_path)
    else
      _ -> nil
    end
  end

  defp ensure_directory(path) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    :ok
  end

  defp ensure_directory(_), do: :ok
end
