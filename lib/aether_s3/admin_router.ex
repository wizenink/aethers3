defmodule AetherS3.AdminRouter do
  @moduledoc """
  Operational endpoints on a dedicated port (see `AETHER_ADMIN_PORT`), separate
  from the S3 API so they need no SigV4 signature, don't collide with bucket
  names, and can be firewalled off from public traffic.

    * `GET /health`   — liveness: 200 as long as the process can respond.
    * `GET /ready`    — data-plane readiness: 200 if the core services that serve
      object traffic are up (this node can serve/proxy objects even if the control
      plane is unavailable), else 503.
    * `GET /ready/cp` — control-plane readiness: 200 only if a bounded,
      leader-routed Khepri probe actually commits (catches a phantom leader or
      lost quorum, unlike a cached leaderboard lookup), else 503.
    * `GET /metrics` — Prometheus exposition (`AetherS3.Telemetry.scrape/0`).
    * `GET /cluster` — best-effort JSON snapshot of every node's view
      (`AetherS3.Cluster.Status.snapshot/0`); handy during a partition.
    * `/admin/*` — dynamic identity management (`AetherS3.Admin.ApiRouter`),
      gated by a bootstrap bearer token. The probe endpoints above stay open.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/ready" do
    if data_ready?() do
      send_resp(conn, 200, "ready")
    else
      send_resp(conn, 503, "not ready")
    end
  end

  get "/ready/cp" do
    if cp_ready?() do
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

  forward("/admin", to: AetherS3.Admin.ApiRouter)

  match _ do
    send_resp(conn, 404, "not found")
  end

  @ready_probe_default_ms 2_000

  # Data plane: object reads/writes need the ring + local metadata store, not the
  # control-plane leader. If these are up the node can serve/proxy objects.
  defp data_ready? do
    alive?(AetherS3.Cluster.RingServer) and alive?(AetherS3.ObjectMeta.DB)
  end

  defp alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # Control plane: an actual bounded, leader-routed (linearizable) query — it
  # commits only if a reachable leader holds quorum, so a phantom leader or lost
  # quorum reads as NOT ready (a cached leaderboard lookup would lie).
  defp cp_ready? do
    timeout = Application.get_env(:aether_s3, :ready_probe_timeout, @ready_probe_default_ms)

    case :khepri.exists(:khepri, [:buckets], %{favor: :consistency, timeout: timeout}) do
      result when is_boolean(result) -> true
      _ -> false
    end
  end
end
