defmodule AetherConsoleWeb.ErrorHTML do
  use AetherConsoleWeb, :html

  # Render the bare status message (e.g. "Not Found") for any error template.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
