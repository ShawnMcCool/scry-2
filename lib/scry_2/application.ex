defmodule Scry2.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Scry2.Config.load!()

    install_console_handler()

    children =
      [
        Scry2Web.Telemetry,
        Scry2.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:scry_2, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:scry_2, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Scry2.PubSub},
        # Buffer must start AFTER Repo and PubSub — it reads persisted filter
        # + buffer size from Scry2.Settings in init/1 and broadcasts appends
        # via PubSub. Logs emitted before this starts are dropped silently by
        # Buffer.append/2's Process.whereis guard.
        Scry2.Console.Buffer,
        {Oban, Application.fetch_env!(:scry_2, Oban)},
        Scry2Web.Endpoint
      ]
      |> maybe_add_watcher()

    opts = [strategy: :one_for_one, name: Scry2.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Install the Erlang :logger handler that funnels all log events into
  # Scry2.Console.Buffer. Safe to call on reboot — re-adds cleanly if the
  # previous handler was left behind (e.g. after a LiveReload crash).
  defp install_console_handler do
    _ = :logger.remove_handler(:scry2_console)

    :ok =
      :logger.add_handler(
        :scry2_console,
        Scry2.Console.Handler,
        %{level: :all, config: %{}}
      )
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Scry2Web.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Only add the MTGA log watcher + ingesters if configuration says so.
  # Off by default in the test env (see config/test.exs) so tests can
  # start them explicitly via the public API when they need to.
  defp maybe_add_watcher(children) do
    if Scry2.Config.get(:start_watcher) do
      children ++
        [
          Scry2.MtgaLogs.Watcher,
          Scry2.Matches.Ingester,
          Scry2.Drafts.Ingester
        ]
    else
      children
    end
  end
end
