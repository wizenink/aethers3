defmodule AetherConsoleWeb.Layouts do
  use AetherConsoleWeb, :html

  # Root layout: the HTML skeleton. The whole console is dark-committed; the theme
  # toggle (data-theme) shifts midnight↔dusk. app.css is the shared design system.
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>aethers3 console</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  # App layout: full-viewport shell, no chrome of its own — the LiveView renders it all.
  def app(assigns) do
    ~H"{@inner_content}"
  end
end
