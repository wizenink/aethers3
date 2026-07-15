defmodule AetherConsole.AuthTest do
  # Not async: mutates the global :aether_console app env.
  use ExUnit.Case, async: false
  alias AetherConsole.Auth

  @stub AetherConsole.AuthStub

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

  test "an admin identity verifies, and the request is SigV4-signed" do
    Req.Test.stub(@stub, fn conn ->
      assert Enum.any?(conn.req_headers, fn {k, v} ->
               k == "authorization" and String.starts_with?(v, "AWS4-HMAC-SHA256")
             end)

      Req.Test.json(conn, %{user: "root", admin: true})
    end)

    assert Auth.verify("AKIAEXAMPLE", "devsecret") == {:ok, %{user: "root", admin: true}}
  end

  test "a valid but non-admin identity is rejected" do
    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{user: "bob", admin: false}) end)
    assert Auth.verify("AKIA", "secret") == {:error, :not_admin}
  end

  test "a rejected signature (403) is :invalid" do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"nope"})) end)
    assert Auth.verify("AKIA", "wrong") == {:error, :invalid}
  end

  test "an unreachable node is :unavailable" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert Auth.verify("AKIA", "secret") == {:error, :unavailable}
  end

  test "an auth-disabled cluster logs in open" do
    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{auth_disabled: true, admin: true}) end)
    assert Auth.verify("anything", "anything") == {:ok, %{user: "auth-disabled", admin: true}}
  end

  defp restore(key, nil), do: Application.delete_env(:aether_console, key)
  defp restore(key, val), do: Application.put_env(:aether_console, key, val)
end
