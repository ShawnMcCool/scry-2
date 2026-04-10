defmodule Scry2Web.Router do
  use Scry2Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Scry2Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Card image cache — served from disk with immutable browser caching.
  # Outside the :browser pipeline (no CSRF, no session — just a static file).
  get "/images/cards/:arena_id", Scry2Web.Plugs.CardImage, :call

  scope "/", Scry2Web do
    pipe_through :browser

    live_session :default, on_mount: {Scry2Web.PlayerScope, :default} do
      live "/", DashboardLive, :index
      live "/stats", StatsLive, :index
      live "/ranks", RanksLive, :index
      live "/economy", EconomyLive, :index
      live "/matches", MatchesLive, :index
      live "/matches/:id", MatchesLive, :show
      live "/cards", CardsLive, :index
      live "/decks", DecksLive, :index
      live "/decks/:deck_id", DecksLive, :show
      live "/drafts", DraftsLive, :index
      live "/drafts/:id", DraftsLive, :show
      live "/events", EventsLive, :index
      live "/events/:id", EventsLive, :show
      live "/mulligans", MulligansLive, :index
      live "/settings", SettingsLive, :index
      live "/operations", OperationsLive, :index
      live "/console", ConsolePageLive, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", Scry2Web do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:scry_2, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Scry2Web.Telemetry
    end
  end
end
