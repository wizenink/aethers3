defmodule AetherS3.ControlPlane.CpTimeoutTest do
  # A wedged control plane (no reachable Raft leader) must fail fast, not hang.
  # We simulate it deterministically with cp_timeout: 0, which makes every Khepri
  # command time out even against a healthy store.
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias AetherS3.ControlPlane.Store

  @router_opts AetherS3.Router.init([])
  @admin_opts AetherS3.AdminRouter.init([])

  setup do
    Application.put_env(:aether_s3, :cp_timeout, 0)
    on_exit(fn -> Application.delete_env(:aether_s3, :cp_timeout) end)
    :ok
  end

  test "control-plane writes surface :unavailable instead of hanging" do
    assert Store.create_bucket("cpt-#{uniq()}", "root") == {:error, :unavailable}
    assert Store.put_user("cpt-#{uniq()}", false) == {:error, :unavailable}
    assert Store.put_group("cpt-#{uniq()}", []) == {:error, :unavailable}
  end

  test "control-plane reads degrade to empty/nil, not a hang" do
    assert Store.get_bucket("cpt-#{uniq()}") == nil
    assert Store.list_users() == []
  end

  test "the S3 router maps a wedged control plane to 503" do
    conn = AetherS3.Router.call(conn(:put, "/cpt-#{uniq()}"), @router_opts)
    assert conn.status == 503
  end

  test "the admin API maps a wedged control plane to 503" do
    prev = Application.get_env(:aether_s3, :admin_token)
    Application.put_env(:aether_s3, :admin_token, "t")
    on_exit(fn -> Application.put_env(:aether_s3, :admin_token, prev) end)

    conn =
      conn(:post, "/admin/users", JSON.encode!(%{name: "cpt-#{uniq()}"}))
      |> put_req_header("authorization", "Bearer t")
      |> AetherS3.AdminRouter.call(@admin_opts)

    assert conn.status == 503
  end

  defp uniq, do: System.unique_integer([:positive])
end
