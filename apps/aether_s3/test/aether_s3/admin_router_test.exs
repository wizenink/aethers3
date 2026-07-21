defmodule AetherS3.AdminRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AetherS3.Auth.SigV4

  @opts AetherS3.AdminRouter.init([])

  defp request(method, path) do
    conn(method, path) |> AetherS3.AdminRouter.call(@opts)
  end

  test "GET /health is always 200" do
    conn = request(:get, "/health")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /ready is 200 when the core data-plane services are up" do
    conn = request(:get, "/ready")
    assert conn.status == 200
    assert conn.resp_body == "ready"
  end

  test "GET /ready/cp is 200 when the control plane can commit" do
    wait_for_leader()
    conn = request(:get, "/ready/cp")
    assert conn.status == 200
    assert conn.resp_body == "ready"
  end

  test "GET /ready/cp is 503 when the leader-routed probe can't commit" do
    # Point the probe at a store that doesn't exist so the read reliably fails.
    # (A 0-timeout was racy — a warmed-up consistency read can resolve instantly,
    # so it intermittently returned 200; this flaked in CI.)
    Application.put_env(:aether_s3, :ready_probe_store, :__no_such_store__)
    on_exit(fn -> Application.delete_env(:aether_s3, :ready_probe_store) end)

    conn = request(:get, "/ready/cp")
    assert conn.status == 503
    assert conn.resp_body == "not ready"
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

  describe "GET /whoami" do
    setup do
      prev = Application.get_env(:aether_s3, :require_auth, true)
      Application.put_env(:aether_s3, :require_auth, true)
      on_exit(fn -> Application.put_env(:aether_s3, :require_auth, prev) end)
      :ok
    end

    test "a valid signature returns the resolved identity as JSON" do
      conn =
        conn(:get, "/whoami")
        |> sign("AKIAEXAMPLE", "devsecret")
        |> AetherS3.AdminRouter.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert JSON.decode!(conn.resp_body) == %{"user" => "root", "admin" => true}
    end

    test "a bad signature is 403 + halted" do
      conn =
        conn(:get, "/whoami")
        |> sign("AKIAEXAMPLE", "not-the-real-secret")
        |> AetherS3.AdminRouter.call(@opts)

      assert conn.status == 403
      assert conn.halted
    end

    test "no Authorization header is 401" do
      conn = request(:get, "/whoami")
      assert conn.status == 401
      assert JSON.decode!(conn.resp_body) == %{"error" => "unauthenticated"}
    end

    test "with require_auth off it reports the open state" do
      Application.put_env(:aether_s3, :require_auth, false)
      conn = request(:get, "/whoami")
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"auth_disabled" => true, "admin" => true}
    end
  end

  # In-test SigV4 signer (mirrors a client / aws-cli); host is "" for a test conn,
  # which is exactly what the plug reads, so we sign with that same empty value.
  defp sign(conn, access_key, secret) do
    amz_date = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    date = String.slice(amz_date, 0, 8)
    region = "us-east-1"
    service = "s3"
    payload_hash = "UNSIGNED-PAYLOAD"

    conn =
      conn
      |> put_req_header("x-amz-date", amz_date)
      |> put_req_header("x-amz-content-sha256", payload_hash)

    signed = ["host", "x-amz-content-sha256", "x-amz-date"]
    headers = Enum.map(signed, fn h -> {h, conn |> get_req_header(h) |> List.first() || ""} end)

    canonical = SigV4.canonical_request(conn.method, conn.request_path, "", headers, payload_hash)
    scope = "#{date}/#{region}/#{service}/aws4_request"
    sts = SigV4.string_to_sign(amz_date, scope, canonical)
    signing_key = SigV4.derive_signing_key(secret, date, region, service)
    signature = SigV4.signature(signing_key, sts)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, " <>
        "SignedHeaders=#{Enum.join(signed, ";")}, Signature=#{signature}"

    put_req_header(conn, "authorization", auth)
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
