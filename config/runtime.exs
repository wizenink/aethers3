import Config

# ── Distributed tracing (OpenTelemetry). Off unless an OTLP endpoint is given.
# Set OTEL_EXPORTER_OTLP_ENDPOINT (e.g. http://collector:4318) to export traces
# over OTLP/HTTP. OTEL_TRACES_SAMPLER_ARG (0.0–1.0) ratio-samples in production;
# default samples every trace (fine for dev / low volume).
if otlp = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  delegate =
    case System.get_env("OTEL_TRACES_SAMPLER_ARG") do
      nil -> {:parent_based, %{root: :always_on}}
      ratio -> {:parent_based, %{root: {:trace_id_ratio_based, String.to_float(ratio)}}}
    end

  # Wrap the sampler so operational-probe endpoints (health/metrics/cluster
  # scrapes) are dropped before they reach the backend.
  sampler = {AetherS3.Tracing.Sampler, %{delegate: delegate}}

  config :opentelemetry, traces_exporter: :otlp, sampler: sampler, span_processor: :batch

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: otlp
end

# ── aether_console (web UI): admin base URLs to read live cluster state from.
# Point it at a real cluster, e.g. AETHER_CONSOLE_NODES=http://host1:9001,http://host2:9001
config :aether_console,
       :cluster_nodes,
       (System.get_env("AETHER_CONSOLE_NODES") || "http://localhost:9001")
       |> String.split(",", trim: true)

# Bearer token the console presents to the cluster's /admin API (must match the
# cluster's AETHER_ADMIN_TOKEN). Unset -> Buckets/Identity show "not configured".
config :aether_console, :admin_token, System.get_env("AETHER_CONSOLE_ADMIN_TOKEN")

# How operators log in to the console. :cluster verifies an access key + secret
# against the cluster (SigV4 GET /whoami); :oidc is reserved for a future strategy.
auth_strategy =
  case System.get_env("AETHER_CONSOLE_AUTH", "cluster") do
    "cluster" -> :cluster
    "oidc" -> :oidc
    other -> raise "unknown AETHER_CONSOLE_AUTH: #{other} (expected cluster|oidc)"
  end

config :aether_console, :auth_strategy, auth_strategy

# Prod release endpoint for the console web UI. (Dev is configured in config.exs;
# tests don't boot the endpoint.) The console holds admin creds — bind it on an
# internal network / behind a reverse proxy, and front it with an auth gate.
#
# Gated on the console app being IN the running release: this same runtime.exs is
# loaded by the STORAGE release too, which has no Phoenix endpoint — without this
# guard the storage node would hit the raise below and refuse to boot.
if config_env() == :prod and Code.ensure_loaded?(AetherConsoleWeb.Endpoint) do
  secret_key_base =
    System.get_env("AETHER_CONSOLE_SECRET_KEY_BASE") ||
      raise """
      AETHER_CONSOLE_SECRET_KEY_BASE is not set — the console can't sign sessions.
      Generate one with:  mix phx.gen.secret   (or: openssl rand -base64 48)
      """

  host = System.get_env("AETHER_CONSOLE_HOST", "localhost")
  port = String.to_integer(System.get_env("AETHER_CONSOLE_PORT", "4000"))

  # Websocket origin allowlist. Defaults to the configured host; set a comma list
  # to allow more, or "false" to disable the check (e.g. behind a trusted proxy).
  check_origin =
    case System.get_env("AETHER_CONSOLE_CHECK_ORIGIN") do
      nil -> ["//#{host}"]
      "false" -> false
      list -> String.split(list, ",", trim: true)
    end

  config :aether_console, AetherConsoleWeb.Endpoint,
    server: true,
    url: [host: host, port: port],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    check_origin: check_origin
end

# Everything below configures the STORAGE node. This same runtime.exs is loaded
# when the console runs ALONE (its own release, or `mix phx.server` from
# apps/aether_console), where the AetherS3.* modules aren't in the code path — so
# sections that reference them are guarded on this presence check.
aether_s3_present? = Code.ensure_loaded?(AetherS3.Config)

# Runtime configuration — evaluated on every boot (dev, test, prod releases).
# A single S3 credential pair. Override via env vars in real deployments.
config :aether_s3, :credentials, %{
  System.get_env("AETHER_ACCESS_KEY", "AKIAEXAMPLE") =>
    System.get_env("AETHER_SECRET_KEY", "devsecret")
}

# Config-seeded root identity: an always-present admin so a fresh cluster is
# usable before any keys are minted. The secret lives in config (host-protected),
# not in the encrypted Khepri store.
config :aether_s3, :root_identities, [
  %{
    access_key: System.get_env("AETHER_ROOT_ACCESS_KEY", "AKIAEXAMPLE"),
    secret: System.get_env("AETHER_ROOT_SECRET_KEY", "devsecret"),
    user: "root",
    admin: true
  }
]

# Master key (passphrase) for encrypting per-key secrets at rest; identical on
# every node. Unset when only the config root is used.
config :aether_s3, :master_key, System.get_env("AETHER_MASTER_KEY")

# Bootstrap bearer token gating the admin user/key API on the admin port.
# Unset -> the admin management API is disabled (it refuses every request), so
# a node without a token configured can't have users minted against it.
config :aether_s3, :admin_token, System.get_env("AETHER_ADMIN_TOKEN")

# In-app TLS for the S3 API: set BOTH to PEM file paths to serve HTTPS directly
# (no reverse proxy needed). Unset -> plain HTTP (terminate TLS at a
# Host-preserving proxy instead). The admin port stays HTTP (firewall it).
if cert = System.get_env("AETHER_TLS_CERT"), do: config(:aether_s3, :tls_cert, cert)
if key = System.get_env("AETHER_TLS_KEY"), do: config(:aether_s3, :tls_key, key)

config :aether_s3, :port, String.to_integer(System.get_env("AETHER_PORT", "9000"))

# Operational endpoints (health/readiness/metrics) listen here, separate from the
# S3 API port so they need no auth and can be firewalled independently.
config :aether_s3, :admin_port, String.to_integer(System.get_env("AETHER_ADMIN_PORT", "9001"))

# Per-node operational config (env-driven). Test env keeps the values from
# config/config.exs, so these only apply to dev/prod runtime.
if aether_s3_present? and config_env() != :test do
  config :aether_s3, :data_dir, System.get_env("AETHER_DATA_DIR", "tmp/aether_data")

  config :aether_s3,
         :require_auth,
         System.get_env("AETHER_REQUIRE_AUTH", "true") == "true"

  config :aether_s3,
         :replication_factor,
         String.to_integer(System.get_env("AETHER_REPLICATION_FACTOR", "3"))

  # Write quorum: replicas that must ack before a PUT returns. Higher W trades
  # availability for durability (W=2 survives one node loss). Integer, or
  # "quorum" (majority) / "all". Default 1 (fast, AP, heals async).
  config :aether_s3,
         :write_quorum,
         AetherS3.Config.write_quorum(System.get_env("AETHER_WRITE_QUORUM", "1"))

  # Object-metadata write durability. `group` (default) group-commits: writes
  # don't fsync individually, but a put blocks until a batched fsync makes it
  # durable — same durability as per-write fsync (no acked-then-lost window),
  # much higher throughput under concurrency. `each` restores CubDB's legacy
  # per-write fsync.
  config :aether_s3,
         :objmeta_sync,
         if(System.get_env("AETHER_OBJMETA_SYNC") == "each", do: :each, else: :group)

  # Control-plane read cache TTL, in MILLISECONDS (default 1000). Fronts the hot
  # per-request CP lookups (creds/identity/bucket/groups) so an authenticated object
  # request skips a leader round-trip and survives a brief CP outage (serving the
  # last known-good value). The cost is bounded staleness: a revoked key or changed
  # grant is observed within one TTL on other nodes. Set 0 to disable (always read
  # the CP — strongest consistency, a leader round-trip per request).
  config :aether_s3,
         :cp_cache_ttl_ms,
         String.to_integer(System.get_env("AETHER_CP_CACHE_TTL_MS", "1000"))

  # Control-plane dead-member eviction is OPT-IN: set AETHER_CP_EVICT_GRACE to a
  # number of SECONDS a member must be unreachable before the Ra leader evicts it
  # (one per cycle). Unset/empty = disabled (the safe default — eviction is destructive).
  case System.get_env("AETHER_CP_EVICT_GRACE") do
    g when is_binary(g) and g != "" ->
      config :aether_s3, :cp_evict_grace_ms, String.to_integer(g) * 1000

    _ ->
      :ok
  end

  # Incomplete-multipart-upload reaping is OPT-IN: set AETHER_MPU_REAP_AGE to a
  # number of SECONDS after which an upload with no Complete/Abort is swept (its
  # parts + init marker deleted). The age is measured from the upload's initiation,
  # so an in-flight upload is never touched. Unset/empty = disabled.
  case System.get_env("AETHER_MPU_REAP_AGE") do
    g when is_binary(g) and g != "" ->
      config :aether_s3, :mpu_reap_age_ms, String.to_integer(g) * 1000

    _ ->
      :ok
  end

  # Orphaned staging-temp sweeping is always on (reclaiming a crashed write's temp
  # is never destructive). AETHER_STAGING_SWEEP_AGE overrides the SECONDS a temp
  # must age before it's swept (default 1h) — set it high to protect very slow
  # in-flight writes, or low to reclaim disk sooner.
  case System.get_env("AETHER_STAGING_SWEEP_AGE") do
    g when is_binary(g) and g != "" ->
      config :aether_s3, :staging_sweep_age_ms, String.to_integer(g) * 1000

    _ ->
      :ok
  end

  # Cluster discovery strategy, chosen per deployment:
  #   * AETHER_PEERS set      -> Epmd: connect to a static, comma-separated list of
  #     node names (stable-name deploys). Names must be resolvable; discovery IS
  #     the list.
  #   * AETHER_DNS_QUERY set  -> DNSPoll: resolve that DNS name to peer IPs and
  #     connect to <basename>@<ip> (containers/k8s with a headless service).
  #   * AETHER_GOSSIP=true    -> Gossip: UDP-multicast auto-discovery on the LAN
  #     (no static list / DNS) — ideal for VMs on one network (e.g. Proxmox).
  #     Set AETHER_GOSSIP_SECRET to encrypt gossip so only nodes sharing it join.
  #   * otherwise             -> LocalEpmd: same-host discovery, for local dev.
  topologies =
    cond do
      peers = System.get_env("AETHER_PEERS") ->
        hosts =
          peers |> String.split(",", trim: true) |> Enum.map(&String.to_atom(String.trim(&1)))

        AetherS3.Config.topology(:epmd, hosts)

      query = System.get_env("AETHER_DNS_QUERY") ->
        AetherS3.Config.topology(:dns, %{
          query: query,
          basename: System.get_env("AETHER_NODE_BASENAME", "aether")
        })

      System.get_env("AETHER_GOSSIP") in ["1", "true"] ->
        AetherS3.Config.topology(:gossip, System.get_env("AETHER_GOSSIP_SECRET"))

      true ->
        AetherS3.Config.topology(:local, nil)
    end

  config :libcluster, topologies: topologies
end

# Log level is a runtime knob (change it per deployment without a rebuild, or
# live on a running node via `AetherS3.Config.set_log_level/1` over the remote
# shell). config/config.exs sets the build-time default; this overrides it.
if aether_s3_present? do
  if level = System.get_env("AETHER_LOG_LEVEL") do
    config :logger, level: AetherS3.Config.log_level(level)
  end
end

# Production config file (TOML). Env vars above are the dev/default path; in
# production drop a file at AETHER_CONFIG (default /etc/aether_s3/config.toml) and
# its values override the env-derived ones. Absent file -> no-op (dev/test).
# Node name & cookie are BEAM-level (rel/vm.args.eex, RELEASE_* / ~/.erlang.cookie),
# not application config, so they are NOT set here.
toml_path = System.get_env("AETHER_CONFIG", "/etc/aether_s3/config.toml")

if aether_s3_present? and File.exists?(toml_path) do
  toml = Toml.decode_file!(toml_path)

  # The unit/type conversions live in AetherS3.Config (tested); here we just apply
  # whatever keys the file set. Seconds→ms, "quorum"→:quorum, etc. happen there.
  for {key, value} <- AetherS3.Config.app_config_from_toml(toml) do
    config :aether_s3, key, value
  end

  if v = toml["log_level"], do: config(:logger, level: AetherS3.Config.log_level(v))

  if roots = AetherS3.Config.root_identities_from_toml(toml),
    do: config(:aether_s3, :root_identities, roots)

  if topologies = AetherS3.Config.topology_from_toml(toml),
    do: config(:libcluster, topologies: topologies)
end
