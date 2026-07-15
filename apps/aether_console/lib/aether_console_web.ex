defmodule AetherConsoleWeb do
  @moduledoc """
  Entrypoint for the web layer — `use AetherConsoleWeb, :live_view` / `:html` /
  `:router` pulls in the right imports.
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html],
        layouts: [html: AetherConsoleWeb.Layouts]

      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {AetherConsoleWeb.Layouts, :app}
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      alias Phoenix.LiveView.JS
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AetherConsoleWeb.Endpoint,
        router: AetherConsoleWeb.Router,
        statics: AetherConsoleWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
