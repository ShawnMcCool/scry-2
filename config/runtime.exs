import Config

# Enables the Phoenix HTTP server when the PHX_SERVER env var is set,
# or automatically when running as a mix release (RELEASE_NAME is set
# by the release launcher).
if System.get_env("PHX_SERVER") || System.get_env("RELEASE_NAME") do
  config :scry_2, Scry2Web.Endpoint, server: true
end

if config_env() == :prod do
  config :scry_2, Scry2Web.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4002"))]

  # ── Bootstrap config resolution ─────────────────────────────────────────
  # Read config.toml if present. On first run it may not exist yet —
  # Scry2.Config.load!/0 will generate it during Application.start/2.
  toml_path =
    case :os.type() do
      {:win32, _} ->
        Path.join([
          System.get_env("APPDATA") || System.user_home!(),
          "scry_2",
          "config.toml"
        ])

      _ ->
        Path.expand("~/.config/scry_2/config.toml")
    end

  toml =
    with {:ok, contents} <- File.read(toml_path),
         {:ok, parsed} <- Toml.decode(contents) do
      parsed
    else
      _ -> %{}
    end

  # Platform-appropriate default database path (used on first run before
  # config.toml exists).
  default_db_path =
    case :os.type() do
      {:win32, _} ->
        Path.join([
          System.get_env("LOCALAPPDATA") || System.user_home!(),
          "scry_2",
          "scry_2.db"
        ])

      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", "scry_2", "scry_2.db"])

      _ ->
        Path.expand("~/.local/share/scry_2/scry_2.db")
    end

  database_path =
    System.get_env("DATABASE_PATH") ||
      get_in(toml, ["database", "path"]) ||
      default_db_path

  config :scry_2, Scry2.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    busy_timeout: 500

  # Secret key base: env var → TOML → random.
  # On first boot the TOML doesn't exist yet, so a random key is used for
  # that one boot. Scry2.Config.load!/0 writes the TOML (with a stable key)
  # during Application.start/2, so all subsequent boots use the persisted key.
  # For a localhost-only app this one-boot inconsistency is harmless
  # (no persistent sessions are lost; LiveView just reconnects).
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      toml["secret_key_base"] ||
      Base.encode64(:crypto.strong_rand_bytes(64))

  config :scry_2, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :scry_2, Scry2Web.Endpoint,
    url: [host: "localhost", port: 4002, scheme: "http"],
    http: [
      # Bind to localhost only — this is a local desktop tool, not a server.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base
end
