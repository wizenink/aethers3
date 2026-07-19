defmodule AetherS3.Application do
  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")
    port = Application.get_env(:aether_s3, :port, 9000)
    admin_port = Application.get_env(:aether_s3, :admin_port, 9001)

    # Inbound S3 request spans (only when an OTLP exporter is configured — see
    # AetherS3.Tracing / runtime.exs). Attaches Bandit telemetry handlers.
    if AetherS3.Tracing.enabled?(), do: OpentelemetryBandit.setup()

    children =
      cluster_children() ++
        [
          # Metrics first, so its telemetry handlers are attached before any
          # request or measurement fires.
          {AetherS3.Telemetry, []},
          {AetherS3.Cluster.RingServer, name: AetherS3.Cluster.RingServer},
          Supervisor.child_spec(
            {CubDB, data_dir: Path.join(data_dir, "objmeta"), name: AetherS3.ObjectMeta.DB},
            id: :objmeta_db
          ),
          # Read-through cache for hot CP lookups (creds/identity/bucket/groups) —
          # up before Khepri so the first request's misses just fall through.
          {AetherS3.ControlPlane.Cache, []},
          {AetherS3.ControlPlane.Khepri, name: AetherS3.ControlPlane.Khepri},
          {AetherS3.ControlPlane.Cluster, name: AetherS3.ControlPlane.Cluster},
          {AetherS3.Replication.AntiEntropy, name: AetherS3.Replication.AntiEntropy},
          {AetherS3.Replication.Reaper, name: AetherS3.Replication.Reaper},
          {Bandit, s3_bandit_opts(port)},
          Supervisor.child_spec(
            {Bandit, plug: AetherS3.AdminRouter, scheme: :http, port: admin_port},
            id: :admin_bandit
          )
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AetherS3.Supervisor)
  end

  # Serve the S3 API over HTTPS when a cert + key are configured, else plain HTTP
  # (terminate TLS at a Host-preserving proxy — SigV4 signs Host).
  defp s3_bandit_opts(port) do
    cert = Application.get_env(:aether_s3, :tls_cert)
    key = Application.get_env(:aether_s3, :tls_key)

    if is_binary(cert) and is_binary(key) do
      [plug: AetherS3.Router, port: port, scheme: :https, certfile: cert, keyfile: key]
    else
      [plug: AetherS3.Router, port: port, scheme: :http]
    end
  end

  # libcluster's LocalEpmd strategy needs a distributed node (epmd). A plain
  # `mix run` is nonode@nohost (single-node) — skip libcluster there so it boots.
  defp cluster_children do
    if Node.alive?() do
      [
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: AetherS3.ClusterSupervisor]]}
      ]
    else
      []
    end
  end
end
