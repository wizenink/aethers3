defmodule AetherS3.Config do
  @moduledoc """
  Pure helpers that translate deployment inputs into application configuration,
  plus a small runtime operation (live log level). Kept out of `runtime.exs` so
  the unit/type conversions (seconds → ms, `"quorum"` → `:quorum`, a TOML
  `[cluster]` section → a libcluster topology) live in one place and are
  unit-testable, and so `runtime.exs` stays a thin "read inputs, apply config"
  layer. Every function here is safe to call from `runtime.exs` (no running app).
  """

  # Levels accepted by `Logger.configure(level: ...)`.
  @log_levels ~w(emergency alert critical error warning notice info debug all none)

  @doc """
  Parse a write-quorum setting to `:quorum` | `:all` | a positive integer.
  Accepts the already-parsed atoms/ints or their string forms (env or TOML).
  """
  def write_quorum(:quorum), do: :quorum
  def write_quorum(:all), do: :all
  def write_quorum("quorum"), do: :quorum
  def write_quorum("all"), do: :all
  def write_quorum(n) when is_integer(n), do: n
  def write_quorum(n) when is_binary(n), do: String.to_integer(n)

  @doc """
  Validate a log-level string and return the atom, raising on anything not
  accepted by `Logger` (fail-fast at boot beats a silently-ignored typo).
  """
  def log_level(level) when level in @log_levels, do: String.to_atom(level)

  def log_level(level) do
    raise ArgumentError,
          "invalid log level #{inspect(level)} (expected one of: #{Enum.join(@log_levels, ", ")})"
  end

  @doc """
  Change the log level of the *running* system, immediately and without a
  restart. Meant to be called over the release remote shell, e.g.:

      bin/aether_s3 rpc 'AetherS3.Config.set_log_level("debug")'
  """
  def set_log_level(level), do: Logger.configure(level: log_level(level))

  @doc "libcluster topology keyword for a discovery strategy and its options."
  def topology(:epmd, hosts) when is_list(hosts),
    do: [aether: [strategy: Cluster.Strategy.Epmd, config: [hosts: hosts]]]

  def topology(:dns, %{query: query, basename: basename}),
    do: [
      aether: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [polling_interval: 5_000, query: query, node_basename: basename]
      ]
    ]

  def topology(:gossip, secret),
    do: [aether: [strategy: Cluster.Strategy.Gossip, config: gossip_config(secret)]]

  def topology(:local, _),
    do: [aether: [strategy: Cluster.Strategy.LocalEpmd]]

  defp gossip_config(secret) when secret in [nil, ""], do: []
  defp gossip_config(secret), do: [secret: secret]

  @doc """
  Translate a decoded TOML map into an `:aether_s3` config keyword list,
  including only the keys the file actually sets (so an absent key never clobbers
  the env-derived default). Unit conversions (`*_grace`/`*_age` seconds → ms,
  `write_quorum` string → term) happen here.
  """
  def app_config_from_toml(toml) do
    []
    |> put(toml, "port", :port)
    |> put(toml, "admin_port", :admin_port)
    |> put(toml, "data_dir", :data_dir)
    |> put(toml, "replication_factor", :replication_factor)
    |> put(toml, "credentials", :credentials)
    |> put(toml, "master_key", :master_key)
    |> put(toml, "admin_token", :admin_token)
    |> put(toml, "tls_cert", :tls_cert)
    |> put(toml, "tls_key", :tls_key)
    |> put(toml, "cp_cache_ttl_ms", :cp_cache_ttl_ms)
    |> put(toml, "cp_evict_grace", :cp_evict_grace_ms, &(&1 * 1000))
    |> put(toml, "mpu_reap_age", :mpu_reap_age_ms, &(&1 * 1000))
    |> put(toml, "staging_sweep_age", :staging_sweep_age_ms, &(&1 * 1000))
    |> put(toml, "write_quorum", :write_quorum, &write_quorum/1)
    |> put(toml, "require_auth", :require_auth)
    |> Enum.reverse()
  end

  @doc "Topology from a decoded TOML `[cluster]` section, or nil if absent."
  def topology_from_toml(toml) do
    case toml["cluster"] do
      nil ->
        nil

      cluster ->
        case cluster["strategy"] do
          "dns" ->
            topology(:dns, %{
              query: cluster["dns_query"],
              basename: cluster["node_basename"] || "aether"
            })

          "epmd" ->
            topology(:epmd, Enum.map(cluster["peers"] || [], &String.to_atom/1))

          "gossip" ->
            topology(:gossip, cluster["secret"])

          _ ->
            topology(:local, nil)
        end
    end
  end

  @doc """
  Config-seeded root identities from a TOML `[[root_identities]]` array of tables,
  or nil if absent. Each entry maps `secret_key` -> the internal `:secret`, and
  defaults `user` to `"root"` and `admin` to `true`.
  """
  def root_identities_from_toml(toml) do
    case toml["root_identities"] do
      list when is_list(list) ->
        Enum.map(list, fn id ->
          %{
            access_key: id["access_key"],
            secret: id["secret_key"] || id["secret"],
            user: id["user"] || "root",
            admin: Map.get(id, "admin", true)
          }
        end)

      _ ->
        nil
    end
  end

  # Append {cfg_key, transform.(value)} only if the TOML key is present. Testing
  # key presence (not truthiness) matters for booleans like require_auth = false.
  defp put(acc, toml, toml_key, cfg_key, transform \\ & &1) do
    if Map.has_key?(toml, toml_key),
      do: [{cfg_key, transform.(toml[toml_key])} | acc],
      else: acc
  end
end
