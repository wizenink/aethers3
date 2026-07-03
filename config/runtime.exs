import Config

# Runtime configuration — evaluated on every boot (dev, test, prod releases).
# A single S3 credential pair. Override via env vars in real deployments.
config :aether_s3, :credentials, %{
  System.get_env("AETHER_ACCESS_KEY", "AKIAEXAMPLE") =>
    System.get_env("AETHER_SECRET_KEY", "devsecret")
}

config :aether_s3, :port, String.to_integer(System.get_env("AETHER_PORT", "9000"))

# Per-node operational config (env-driven). Test env keeps the values from
# config/config.exs, so these only apply to dev/prod runtime.
if config_env() != :test do
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
  write_quorum =
    case System.get_env("AETHER_WRITE_QUORUM", "1") do
      "quorum" -> :quorum
      "all" -> :all
      n -> String.to_integer(n)
    end

  config :aether_s3, :write_quorum, write_quorum

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

        [aether: [strategy: Cluster.Strategy.Epmd, config: [hosts: hosts]]]

      query = System.get_env("AETHER_DNS_QUERY") ->
        [
          aether: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: query,
              node_basename: System.get_env("AETHER_NODE_BASENAME", "aether")
            ]
          ]
        ]

      System.get_env("AETHER_GOSSIP") in ["1", "true"] ->
        secret = System.get_env("AETHER_GOSSIP_SECRET")
        gossip_config = if secret, do: [secret: secret], else: []
        [aether: [strategy: Cluster.Strategy.Gossip, config: gossip_config]]

      true ->
        [aether: [strategy: Cluster.Strategy.LocalEpmd]]
    end

  config :libcluster, topologies: topologies
end

# Production config file (TOML). Env vars above are the dev/default path; in
# production drop a file at AETHER_CONFIG (default /etc/aether_s3/config.toml) and
# its values override the env-derived ones. Absent file -> no-op (dev/test).
# Node name & cookie are BEAM-level (rel/vm.args.eex, RELEASE_* / ~/.erlang.cookie),
# not application config, so they are NOT set here.
toml_path = System.get_env("AETHER_CONFIG", "/etc/aether_s3/config.toml")

if File.exists?(toml_path) do
  toml = Toml.decode_file!(toml_path)

  if v = toml["port"], do: config(:aether_s3, :port, v)
  if v = toml["data_dir"], do: config(:aether_s3, :data_dir, v)
  if v = toml["replication_factor"], do: config(:aether_s3, :replication_factor, v)
  if v = toml["credentials"], do: config(:aether_s3, :credentials, v)

  # Dead-member eviction grace, in SECONDS (opt-in; omit to disable).
  if v = toml["cp_evict_grace"], do: config(:aether_s3, :cp_evict_grace_ms, v * 1000)

  # Incomplete-multipart-upload reap age, in SECONDS (opt-in; omit to disable).
  if v = toml["mpu_reap_age"], do: config(:aether_s3, :mpu_reap_age_ms, v * 1000)

  # require_auth may legitimately be false, so test key presence, not truthiness.
  if Map.has_key?(toml, "require_auth"),
    do: config(:aether_s3, :require_auth, toml["require_auth"])

  if v = toml["write_quorum"] do
    quorum =
      case v do
        "quorum" -> :quorum
        "all" -> :all
        n when is_integer(n) -> n
      end

    config :aether_s3, :write_quorum, quorum
  end

  if cluster = toml["cluster"] do
    topologies =
      case cluster["strategy"] do
        "dns" ->
          [
            aether: [
              strategy: Cluster.Strategy.DNSPoll,
              config: [
                polling_interval: 5_000,
                query: cluster["dns_query"],
                node_basename: cluster["node_basename"] || "aether"
              ]
            ]
          ]

        "epmd" ->
          hosts = Enum.map(cluster["peers"] || [], &String.to_atom/1)
          [aether: [strategy: Cluster.Strategy.Epmd, config: [hosts: hosts]]]

        "gossip" ->
          gossip_config = if s = cluster["secret"], do: [secret: s], else: []
          [aether: [strategy: Cluster.Strategy.Gossip, config: gossip_config]]

        _ ->
          [aether: [strategy: Cluster.Strategy.LocalEpmd]]
      end

    config :libcluster, topologies: topologies
  end
end
