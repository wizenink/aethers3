defmodule AetherS3.Application do
  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")
    port = Application.get_env(:aether_s3, :port, 9000)

    children =
      cluster_children() ++
        [
          {AetherS3.Cluster.RingServer, name: AetherS3.Cluster.RingServer},
          Supervisor.child_spec(
            {CubDB, data_dir: Path.join(data_dir, "objmeta"), name: AetherS3.ObjectMeta.DB},
            id: :objmeta_db
          ),
          {AetherS3.ControlPlane.Khepri, name: AetherS3.ControlPlane.Khepri},
          {AetherS3.ControlPlane.Cluster, name: AetherS3.ControlPlane.Cluster},
          {Registry, keys: :unique, name: AetherS3.UploadRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: AetherS3.UploadSupervisor},
          {AetherS3.Replication.AntiEntropy, name: AetherS3.Replication.AntiEntropy},
          {Bandit, plug: AetherS3.Router, scheme: :http, port: port}
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AetherS3.Supervisor)
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
