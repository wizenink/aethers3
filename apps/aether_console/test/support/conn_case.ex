defmodule AetherConsoleWeb.ConnCase do
  @moduledoc """
  Test case for tests that need a connection against the console endpoint.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use AetherConsoleWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest

      @endpoint AetherConsoleWeb.Endpoint
    end
  end

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
