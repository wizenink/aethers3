defmodule AetherS3.ControlPlane.Store do
  @behaviour AetherS3.ControlPlane
  @db AetherS3.ControlPlane.DB

  @impl AetherS3.ControlPlane
  def create_bucket(name) do
    CubDB.put(@db, name, %{created_at: DateTime.utc_now()})
  end

  @impl AetherS3.ControlPlane
  def bucket_exists?(name) do
    case CubDB.get(@db, name) do
      nil -> false
      _ -> true
    end
  end

  @impl AetherS3.ControlPlane
  def delete_bucket(name) do
    case AetherS3.ObjectMeta.Store.list(name) do
      [] -> CubDB.delete(@db, name)
      _ -> {:error, :not_empty}
    end
  end
end
