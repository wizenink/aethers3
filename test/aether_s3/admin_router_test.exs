defmodule AetherS3.AdminRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts AetherS3.AdminRouter.init([])

  defp request(method, path) do
    conn(method, path) |> AetherS3.AdminRouter.call(@opts)
  end

  test "GET /health is always 200" do
    conn = request(:get, "/health")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /ready is 200 once Khepri has elected a leader" do
    wait_for_leader()
    conn = request(:get, "/ready")
    assert conn.status == 200
    assert conn.resp_body == "ready"
  end

  test "GET /metrics serves Prometheus text with our gauges" do
    # Force a poller sample so the aether.* gauges are registered before scraping;
    # :telemetry.execute runs the reporter's handler synchronously.
    AetherS3.Telemetry.dispatch_cluster_metrics()

    conn = request(:get, "/metrics")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
    assert conn.resp_body =~ "aether_cluster_nodes"
    assert conn.resp_body =~ "aether_cluster_khepri_leader"
    assert conn.resp_body =~ "aether_cluster_objects"
  end

  test "GET /cluster returns a JSON snapshot with the leader and this node's view" do
    wait_for_leader()
    conn = request(:get, "/cluster")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    snapshot = JSON.decode!(conn.resp_body)
    assert snapshot["node_count"] >= 1
    self_view = snapshot["nodes"][to_string(Node.self())]
    assert self_view["members"] == 1
    assert is_integer(self_view["objects"])
  end

  test "unknown admin path is 404" do
    assert request(:get, "/nope").status == 404
  end

  defp wait_for_leader(retries \\ 40) do
    case :ra_leaderboard.lookup_leader(:khepri) do
      {:khepri, _} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(50)
        wait_for_leader(retries - 1)

      _ ->
        :ok
    end
  end
end
