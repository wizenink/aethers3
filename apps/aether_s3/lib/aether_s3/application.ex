defmodule AetherS3.Application do
  use Application
  require Logger

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
          {AetherS3.Cluster.RingServer, name: AetherS3.Cluster.RingServer}
        ] ++
        objmeta_children(data_dir) ++
        [
          # Read-through cache for hot CP lookups (creds/identity/bucket/groups) —
          # up before Khepri so the first request's misses just fall through.
          {AetherS3.ControlPlane.Cache, []},
          {AetherS3.ControlPlane.Khepri, name: AetherS3.ControlPlane.Khepri},
          {AetherS3.ControlPlane.Cluster, name: AetherS3.ControlPlane.Cluster},
          {AetherS3.Replication.AntiEntropy, name: AetherS3.Replication.AntiEntropy},
          {AetherS3.Replication.Reaper, name: AetherS3.Replication.Reaper},
          # Opt-in bitrot scrub (returns :ignore unless AETHER_SCRUB_INTERVAL is set).
          {AetherS3.Storage.Scrubber, []},
          Supervisor.child_spec(
            {Bandit,
             s3_bandit_opts(port) ++ [thousand_island_options: [shutdown_timeout: 25_000]]},
            id: :s3_bandit,
            shutdown: 30_000
          ),
          Supervisor.child_spec(
            {Bandit, plug: AetherS3.AdminRouter, scheme: :http, port: admin_port},
            id: :admin_bandit
          )
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AetherS3.Supervisor)
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Shutdown: draining (readiness -> 503)")
    AetherS3.Shutdown.begin_draining()
    Process.sleep(Application.get_env(:aether_s3, :shutdown_drain_ms, 5000))
    state
  end

  # The object-metadata store (CubDB), plus — in :group mode — the group-commit
  # coordinator. `:group` (default) opens CubDB without per-write fsync and lets
  # AetherS3.ObjectMeta.GroupCommit batch one fsync across concurrent writers
  # (same durability as per-write fsync — a put returns only once on disk — but
  # far higher throughput). `:each` restores CubDB's per-write fsync (no
  # coordinator), the legacy behaviour.
  defp objmeta_children(data_dir) do
    sync = Application.get_env(:aether_s3, :objmeta_sync, :group)

    cubdb =
      Supervisor.child_spec(
        {CubDB,
         data_dir: Path.join(data_dir, "objmeta"),
         name: AetherS3.ObjectMeta.DB,
         auto_file_sync: sync == :each},
        id: :objmeta_db
      )

    case sync do
      :group -> [cubdb, AetherS3.ObjectMeta.GroupCommit]
      _ -> [cubdb]
    end
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
