defmodule ConcilioWeb.Router do
  use ConcilioWeb, :router

  import ConcilioWeb.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConcilioWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_session_user
  end

  pipeline :authenticated do
    plug :require_authenticated
  end

  pipeline :guest do
    plug :redirect_if_authenticated
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  ## Health probe — used by the Tauri shell to wait on boot, and by
  ## any container orchestrator. Intentionally bypasses auth and
  ## browser plugs (no session, no CSRF, no flash).
  scope "/", ConcilioWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  ## Logout — available authenticated or not (rotates secret either way)
  scope "/", ConcilioWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
  end

  ## Public (unauthenticated) routes
  scope "/", ConcilioWeb do
    pipe_through [:browser, :guest]

    live_session :public do
      live "/login", LoginLive, :new
    end

    post "/login", SessionController, :create
  end

  ## Authenticated routes
  scope "/", ConcilioWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{ConcilioWeb.Auth, :require_authenticated}] do
      live "/", ChatLive, :index
      live "/c/:id", ChatLive, :show

      live "/councils", CouncilIndexLive, :index
      live "/councils/new", CouncilBuilderLive, :new
      live "/councils/:id", CouncilShowLive, :show
      live "/councils/:id/edit", CouncilBuilderLive, :edit

      live "/runs", RunIndexLive, :index
      live "/runs/:id", RunDetailLive, :show

      live "/settings", SettingsLive, :providers
      live "/settings/about", SettingsLive, :about
      live "/settings/providers", SettingsLive, :providers
      live "/settings/defaults", SettingsLive, :defaults
      live "/settings/display", SettingsLive, :display
    end
  end

  # LiveDashboard exposed in dev (Phoenix scaffold default) and in
  # `app` builds (Tauri tray menu opens it). For server deploys the
  # operator can opt in by compiling with `CONCILIO_APP=1` or by
  # toggling :dev_routes in their own config.
  dashboard? =
    Application.compile_env(:concilio, :dev_routes) ||
      Application.compile_env(:concilio, :app_mode?)

  if dashboard? do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ConcilioWeb.Telemetry
    end
  end
end
