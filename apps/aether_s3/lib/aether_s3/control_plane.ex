defmodule AetherS3.ControlPlane do
  @callback create_bucket(name :: String.t(), owner :: String.t() | nil) :: :ok
  @callback bucket_exists?(name :: String.t()) :: boolean()
  @callback get_bucket(name :: String.t()) :: map() | nil
  @callback list_buckets() :: [map()]
  @callback set_bucket_grants(name :: String.t(), grants :: [map()]) ::
              :ok | {:error, :no_such_bucket}
  @callback set_bucket_acl(name :: String.t(), acl :: String.t()) ::
              :ok | {:error, :no_such_bucket}
  @callback set_scoped_grants(name :: String.t(), scope :: String.t(), grants :: [map()]) ::
              :ok | {:error, :no_such_bucket}
  @callback delete_bucket(name :: String.t()) :: :ok | {:error, :not_empty}

  @callback put_group(name :: String.t(), members :: [String.t()]) :: :ok
  @callback get_group(name :: String.t()) :: map() | nil
  @callback list_groups() :: [map()]
  @callback delete_group(name :: String.t()) :: :ok
  @callback add_group_member(name :: String.t(), user :: String.t()) ::
              :ok | {:error, :no_such_group}
  @callback remove_group_member(name :: String.t(), user :: String.t()) ::
              :ok | {:error, :no_such_group}
  @callback groups_of(user :: String.t()) :: [String.t()]

  @callback put_user(name :: String.t(), admin :: boolean()) :: :ok
  @callback get_user(name :: String.t()) :: map() | nil
  @callback list_users() :: [map()]
  @callback delete_user(name :: String.t()) :: :ok
  @callback put_key(access_key :: String.t(), user :: String.t(), secret_enc :: binary()) :: :ok
  @callback get_key(access_key :: String.t()) :: map() | nil
  @callback keys_of(user :: String.t()) :: [String.t()]
  @callback list_keys() :: [map()]
  @callback delete_key(access_key :: String.t()) :: :ok
end
