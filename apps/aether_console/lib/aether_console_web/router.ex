defmodule AetherConsoleWeb.Router do
  use AetherConsoleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AetherConsoleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", AetherConsoleWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    # All console views live behind LiveView, so the auth gate is an on_mount hook:
    # no session identity → redirect to /login.
    live_session :require_user, on_mount: {AetherConsoleWeb.Auth, :require_user} do
      live "/", ConsoleLive, :cluster
      live "/buckets", ConsoleLive, :buckets
      live "/identity", ConsoleLive, :identity
      live "/objects", ConsoleLive, :objects
    end
  end
end
