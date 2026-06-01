defmodule AetherS3.ControlPlane do
  @callback create_bucket(name :: String.t()) :: :ok
  @callback bucket_exists?(name :: String.t()) :: boolean()
  @callback delete_bucket(name :: String.t()) :: :ok | {:error, :not_empty}
end
