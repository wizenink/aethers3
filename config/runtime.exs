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

  # Cluster discovery strategy, chosen per deployment:
  #   * AETHER_DNS_QUERY set  -> DNSPoll: resolve that DNS name to peer IPs and
  #     connect to <basename>@<ip> (works across machines/containers/k8s where a
  #     headless service / Docker DNS returns all node IPs).
  #   * otherwise             -> LocalEpmd: same-host discovery, for local dev.
  topologies =
    case System.get_env("AETHER_DNS_QUERY") do
      nil ->
        [aether: [strategy: Cluster.Strategy.LocalEpmd]]

      query ->
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
    end

  config :libcluster, topologies: topologies
end
