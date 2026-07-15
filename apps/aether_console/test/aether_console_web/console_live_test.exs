defmodule AetherConsoleWeb.ConsoleLiveTest do
  # Not async: mutates the global :aether_console app env.
  use AetherConsoleWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    prev = Application.get_env(:aether_console, :cluster_nodes)
    # No nodes → Cluster.snapshot is offline (connected: false), so the view mounts
    # without any network call.
    Application.put_env(:aether_console, :cluster_nodes, [])

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:aether_console, :cluster_nodes)
        val -> Application.put_env(:aether_console, :cluster_nodes, val)
      end
    end)

    :ok
  end

  test "an unauthenticated request is redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "an authenticated admin mounts the cluster view", %{conn: conn} do
    conn =
      Plug.Test.init_test_session(conn, %{"console_user" => %{"user" => "root", "admin" => true}})

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Cluster"
    assert html =~ "root"
  end
end
