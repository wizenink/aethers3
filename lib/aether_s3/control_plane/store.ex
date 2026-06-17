defmodule AetherS3.ControlPlane.Store do
  @behaviour AetherS3.ControlPlane

  @impl AetherS3.ControlPlane
  def create_bucket(name) do
    :khepri.put([:buckets, name], %{created_at: DateTime.utc_now()})
  end

  @impl AetherS3.ControlPlane
  def bucket_exists?(name) do
    :khepri.exists([:buckets, name])
  end

  @impl AetherS3.ControlPlane
  def delete_bucket(name) do
    case AetherS3.Replication.Coordinator.list(name) do
      [] -> :khepri.delete([:buckets, name])
      _ -> {:error, :not_empty}
    end
  end
end
