defmodule AetherConsoleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :aether_console

  @session_options [
    store: :cookie,
    key: "_aether_console_key",
    signing_salt: "aC0nsoleS",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Serve built assets + static files from priv/static.
  plug Plug.Static,
    at: "/",
    from: :aether_console,
    gzip: false,
    only: AetherConsoleWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AetherConsoleWeb.Router
end
