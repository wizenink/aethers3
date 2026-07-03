defmodule AetherS3.AdminRouter do
  @moduledoc """
  Operational endpoints on a dedicated port (see `AETHER_ADMIN_PORT`), separate
  from the S3 API so they need no SigV4 signature, don't collide with bucket
  names, and can be firewalled off from public traffic.

    * `GET /health`  — liveness: 200 as long as the process can respond.
    * `GET /ready`   — readiness: 200 once the local Khepri/Raft view has a known
      leader (this node can serve control-plane reads), else 503.
    * `GET /metrics` — Prometheus exposition (`AetherS3.Telemetry.scrape/0`).
    * `GET /cluster` — best-effort JSON snapshot of every node's view
      (`AetherS3.Cluster.Status.snapshot/0`); handy during a partition.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/ready" do
    if ready?() do
      send_resp(conn, 200, "ready")
    else
      send_resp(conn, 503, "not ready")
    end
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, AetherS3.Telemetry.scrape())
  end

  get "/cluster" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(AetherS3.Cluster.Status.snapshot()))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # A known Raft leader means the control plane is reachable from here. This is an
  # ETS lookup (non-blocking), unlike :khepri_cluster.nodes/0 which can wedge.
  defp ready? do
    match?({:khepri, _leader}, :ra_leaderboard.lookup_leader(:khepri))
  end
end
