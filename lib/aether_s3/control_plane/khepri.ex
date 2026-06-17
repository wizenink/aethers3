defmodule AetherS3.ControlPlane.Khepri do
  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def start_link do
    dir = Path.join(Application.get_env(:aether_s3, :data_dir, "tmp/aether_data"), "khepri")
    {:ok, _store} = :khepri.start(dir)
    :ignore
  end
end
