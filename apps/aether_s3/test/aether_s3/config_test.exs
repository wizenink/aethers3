defmodule AetherS3.ConfigTest do
  use ExUnit.Case, async: true

  alias AetherS3.Config

  describe "write_quorum/1" do
    test "parses strings and passes through terms, clamping is left to resolve_w" do
      assert Config.write_quorum("quorum") == :quorum
      assert Config.write_quorum("all") == :all
      assert Config.write_quorum("2") == 2
      assert Config.write_quorum(3) == 3
      assert Config.write_quorum(:quorum) == :quorum
      assert Config.write_quorum(:all) == :all
    end
  end

  describe "log_level/1" do
    test "accepts every level Logger allows" do
      for l <- ~w(emergency alert critical error warning notice info debug all none) do
        assert Config.log_level(l) == String.to_atom(l)
      end
    end

    test "raises on an unknown level (fail-fast at boot)" do
      assert_raise ArgumentError, ~r/invalid log level/, fn -> Config.log_level("verbose") end
    end
  end

  describe "topology/2" do
    test "epmd carries the host list" do
      assert Config.topology(:epmd, [:a@h1, :a@h2]) ==
               [aether: [strategy: Cluster.Strategy.Epmd, config: [hosts: [:a@h1, :a@h2]]]]
    end

    test "dns carries query + basename and a polling interval" do
      assert Config.topology(:dns, %{query: "aether.internal", basename: "aether"}) ==
               [
                 aether: [
                   strategy: Cluster.Strategy.DNSPoll,
                   config: [
                     polling_interval: 5_000,
                     query: "aether.internal",
                     node_basename: "aether"
                   ]
                 ]
               ]
    end

    test "gossip includes the secret when given, omits it otherwise" do
      assert Config.topology(:gossip, "s3cr3t") ==
               [aether: [strategy: Cluster.Strategy.Gossip, config: [secret: "s3cr3t"]]]

      assert Config.topology(:gossip, nil) ==
               [aether: [strategy: Cluster.Strategy.Gossip, config: []]]

      assert Config.topology(:gossip, "") ==
               [aether: [strategy: Cluster.Strategy.Gossip, config: []]]
    end

    test "local uses LocalEpmd" do
      assert Config.topology(:local, nil) == [aether: [strategy: Cluster.Strategy.LocalEpmd]]
    end
  end

  describe "app_config_from_toml/1" do
    test "maps present keys, converting seconds→ms and the quorum term" do
      toml = %{
        "port" => 9000,
        "data_dir" => "/var/lib/aether_s3",
        "replication_factor" => 3,
        "credentials" => %{"AKIA" => "secret"},
        "cp_evict_grace" => 60,
        "mpu_reap_age" => 86_400,
        "staging_sweep_age" => 3600,
        "write_quorum" => "quorum",
        "require_auth" => true
      }

      cfg = Config.app_config_from_toml(toml)

      assert cfg[:port] == 9000
      assert cfg[:data_dir] == "/var/lib/aether_s3"
      assert cfg[:replication_factor] == 3
      assert cfg[:credentials] == %{"AKIA" => "secret"}
      assert cfg[:cp_evict_grace_ms] == 60_000
      assert cfg[:mpu_reap_age_ms] == 86_400_000
      assert cfg[:staging_sweep_age_ms] == 3_600_000
      assert cfg[:write_quorum] == :quorum
      assert cfg[:require_auth] == true
    end

    test "omits absent keys so they never clobber env-derived defaults" do
      assert Config.app_config_from_toml(%{"port" => 8080}) == [port: 8080]
      assert Config.app_config_from_toml(%{}) == []
    end

    test "keeps require_auth = false (presence, not truthiness)" do
      assert Config.app_config_from_toml(%{"require_auth" => false}) == [require_auth: false]
    end
  end

  describe "topology_from_toml/1" do
    test "nil when there is no [cluster] section" do
      assert Config.topology_from_toml(%{"port" => 9000}) == nil
    end

    test "builds each strategy from its [cluster] fields" do
      assert Config.topology_from_toml(%{"cluster" => %{"strategy" => "gossip", "secret" => "x"}}) ==
               [aether: [strategy: Cluster.Strategy.Gossip, config: [secret: "x"]]]

      assert Config.topology_from_toml(%{
               "cluster" => %{"strategy" => "epmd", "peers" => ["a@n1.lan", "a@n2.lan"]}
             }) ==
               [
                 aether: [
                   strategy: Cluster.Strategy.Epmd,
                   config: [hosts: [:"a@n1.lan", :"a@n2.lan"]]
                 ]
               ]

      assert Config.topology_from_toml(%{
               "cluster" => %{"strategy" => "dns", "dns_query" => "aether.internal"}
             }) ==
               [
                 aether: [
                   strategy: Cluster.Strategy.DNSPoll,
                   config: [
                     polling_interval: 5_000,
                     query: "aether.internal",
                     node_basename: "aether"
                   ]
                 ]
               ]

      assert Config.topology_from_toml(%{"cluster" => %{"strategy" => "unknown"}}) ==
               [aether: [strategy: Cluster.Strategy.LocalEpmd]]
    end
  end

  describe "root_identities_from_toml/1" do
    test "nil when there is no [[root_identities]]" do
      assert Config.root_identities_from_toml(%{"port" => 9000}) == nil
    end

    test "maps secret_key -> :secret and defaults user/admin" do
      toml = %{
        "root_identities" => [
          %{"access_key" => "AKIA_R", "secret_key" => "s3cr3t"},
          %{"access_key" => "AKIA_OPS", "secret_key" => "x", "user" => "ops", "admin" => false}
        ]
      }

      assert Config.root_identities_from_toml(toml) == [
               %{access_key: "AKIA_R", secret: "s3cr3t", user: "root", admin: true},
               %{access_key: "AKIA_OPS", secret: "x", user: "ops", admin: false}
             ]
    end
  end
end
