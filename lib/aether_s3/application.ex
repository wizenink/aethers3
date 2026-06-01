defmodule AetherS3.Application do
  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")

    children = [
      Supervisor.child_spec(
        {CubDB, data_dir: Path.join(data_dir, "objmeta"), name: AetherS3.ObjectMeta.DB},
        id: :objmeta_db
      ),
      Supervisor.child_spec(
        {CubDB, data_dir: Path.join(data_dir, "ctrl"), name: AetherS3.ControlPlane.DB},
        id: :ctrl_db
      ),
      {Bandit, plug: AetherS3.Router, scheme: :http, port: 9000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AetherS3.Supervisor)
  end
end
