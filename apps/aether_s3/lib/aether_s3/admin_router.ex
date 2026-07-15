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
    * `GET /whoami` — SigV4-authenticated identity probe: returns the signing
      caller's `{user, admin}` as JSON. Unlike `/admin/*` (bearer token) this is
      per-user, so the web console can verify a login credential and learn whether
      it's an admin. Bad/absent signature → 403/401.
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

  # SigV4-authenticated identity probe. Reuses the S3 auth plug, which resolves the
  # access key and (on a valid signature) assigns `%{user, admin}` — so the console
  # can verify a login credential without the master key. A bad signature is halted
  # with 403 by the plug itself; :anonymous means no usable signature was presented.
  get "/whoami" do
    conn = AetherS3.Plug.SigV4.call(conn, [])

    cond do
      conn.halted ->
        conn

      match?(%{user: _}, conn.assigns[:identity]) ->
        %{user: user, admin: admin} = conn.assigns.identity
        whoami_json(conn, 200, %{user: user, admin: admin})

      conn.assigns[:identity] == :auth_disabled ->
        # require_auth is off (dev): there is no identity to prove. Console login is
        # only meaningful with auth on; report the open state rather than a user.
        whoami_json(conn, 200, %{auth_disabled: true, admin: true})

      true ->
        whoami_json(conn, 401, %{error: "unauthenticated"})
    end
  end

  forward("/admin", to: AetherS3.Admin.ApiRouter)

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp whoami_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
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
