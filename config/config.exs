# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :scry_2,
  ecto_repos: [Scry2.Repo],
  generators: [timestamp_type: :utc_datetime]

# Log Ecto queries at :info (not the Ecto default of :debug). Scry2 is a
# single-user desktop app — query visibility is a diagnostic feature, not
# production noise. This applies in dev AND prod so the user can flip the
# `ecto` chip in the Console drawer and immediately see queries without
# also having to drop the level floor to :debug.
config :scry_2, Scry2.Repo, log: :info

# Oban (SQLite backend via Oban.Engines.Lite)
config :scry_2, Oban,
  engine: Oban.Engines.Lite,
  repo: Scry2.Repo,
  queues: [default: 5, imports: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Daily 04:00 UTC — refresh 17lands card reference data.
       {"0 4 * * *", Scry2.Workers.PeriodicallyUpdateCards}
     ]}
  ]

# Configure the endpoint
config :scry_2, Scry2Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Scry2Web.ErrorHTML, json: Scry2Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Scry2.PubSub,
  live_view: [signing_salt: "Lxv6fW83"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  scry_2: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  scry_2: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
