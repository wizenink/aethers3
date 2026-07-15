defmodule AetherConsoleWeb.SessionControllerTest do
  # Not async: mutates the global :aether_console app env.
  use AetherConsoleWeb.ConnCase, async: false

  @stub AetherConsole.SessionAuthStub

  setup do
    prev_nodes = Application.get_env(:aether_console, :cluster_nodes)
    prev_req = Application.get_env(:aether_console, :auth_req_opts)
    Application.put_env(:aether_console, :cluster_nodes, ["http://node:9001"])
    Application.put_env(:aether_console, :auth_req_opts, plug: {Req.Test, @stub})

    on_exit(fn ->
      restore(:cluster_nodes, prev_nodes)
      restore(:auth_req_opts, prev_req)
    end)

    :ok
  end

  test "GET /login renders the sign-in form", %{conn: conn} do
    assert get(conn, ~p"/login") |> html_response(200) =~ "Sign in"
  end

  test "valid admin credentials set the session and redirect home", %{conn: conn} do
    stub_whoami(200, %{"user" => "root", "admin" => true})
    conn = login(conn, "AKIAEXAMPLE", "devsecret")

    assert redirected_to(conn) == "/"
    assert get_session(conn, "console_user") == %{"user" => "root", "admin" => true}
  end

  test "a rejected credential shows an error and sets no session", %{conn: conn} do
    stub_whoami(403, %{"error" => "denied"})
    conn = login(conn, "AKIA", "wrong")

    assert html_response(conn, 401) =~ "Invalid access key or secret"
    refute get_session(conn, "console_user")
  end

  test "a valid but non-admin credential is rejected", %{conn: conn} do
    stub_whoami(200, %{"user" => "bob", "admin" => false})
    conn = login(conn, "AKIA", "sec")

    assert html_response(conn, 401) =~ "requires an admin identity"
    refute get_session(conn, "console_user")
  end

  test "logout drops the session", %{conn: conn} do
    out =
      conn
      |> Plug.Test.init_test_session(%{"console_user" => %{"user" => "root", "admin" => true}})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> delete(~p"/logout")

    assert redirected_to(out) == "/login"
    # The drop clears the session cookie, so a follow-up request is unauthenticated.
    refute out |> recycle() |> get(~p"/login") |> get_session("console_user")
  end

  defp login(conn, access_key, secret) do
    conn
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
    |> post(~p"/login", %{"access_key" => access_key, "secret_key" => secret})
  end

  defp stub_whoami(status, body) do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, status, Jason.encode!(body)) end)
  end

  defp restore(key, nil), do: Application.delete_env(:aether_console, key)
  defp restore(key, val), do: Application.put_env(:aether_console, key, val)
end
