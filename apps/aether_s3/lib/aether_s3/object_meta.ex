defmodule AetherS3.ObjectMeta do
  @callback put(bucket :: String.t(), key :: String.t(), meta :: map()) :: :ok
  @callback get(bucket :: String.t(), key :: String.t()) :: {:ok, map()} | :not_found
  @callback delete(bucket :: String.t(), key :: String.t()) :: :ok
  @callback list(bucket :: String.t()) :: [{String.t(), map()}]
end
