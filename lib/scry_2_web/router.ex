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

  scope "/", Scry2Web do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/matches", MatchesLive, :index
    live "/matches/:id", MatchesLive, :show
    live "/cards", CardsLive, :index
    live "/drafts", DraftsLive, :index
    live "/drafts/:id", DraftsLive, :show
    live "/settings", SettingsLive, :index
    live "/console", ConsolePageLive, :index
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
