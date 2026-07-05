defmodule AetherS3.Auth.Identity do
  @moduledoc """
  Resolves an access key to the identity + secret needed to verify a SigV4
  signature. Lookup order:

    1. Config-seeded root identities — plaintext secret from config, always
       present so a fresh cluster is usable before any key is minted.
    2. Dynamic keys in Khepri — secret decrypted with the master key.

  Returns `{:ok, %{user, admin, secret}}` for a known key, or `:error` for an
  unknown key (or one whose secret can't be decrypted — we fail closed).
  """
  alias AetherS3.Auth.SecretBox
  alias AetherS3.ControlPlane.Store

  @type identity :: %{user: String.t(), admin: boolean(), secret: String.t()}

  @doc "Resolve an access key to `{:ok, identity}` or `:error`."
  @spec resolve(String.t()) :: {:ok, identity} | :error
  def resolve(access_key) do
    case root_identity(access_key) do
      %{} = root -> {:ok, %{user: root.user, admin: root.admin, secret: root.secret}}
      nil -> resolve_dynamic(access_key)
    end
  end

  @doc "True if the access key resolves to an admin identity."
  @spec admin?(String.t()) :: boolean()
  def admin?(access_key), do: match?({:ok, %{admin: true}}, resolve(access_key))

  defp root_identity(access_key) do
    :aether_s3
    |> Application.get_env(:root_identities, [])
    |> Enum.find(fn id -> id.access_key == access_key end)
  end

  defp resolve_dynamic(access_key) do
    case Store.get_key(access_key) do
      %{user: user, secret_enc: secret_enc} ->
        # A key whose secret won't decrypt fails closed rather than authenticate.
        with {:ok, secret} <- decrypt_secret(secret_enc) do
          {:ok, %{user: user, admin: user_admin?(user), secret: secret}}
        end

      nil ->
        :error
    end
  end

  defp decrypt_secret(secret_enc) do
    case master_key() do
      nil ->
        raise "AETHER_MASTER_KEY is not set, but an encrypted secret exists in Khepri"

      key ->
        SecretBox.decrypt(secret_enc, key)
    end
  end

  defp user_admin?(user) do
    case Store.get_user(user) do
      %{admin: admin} -> admin
      _ -> false
    end
  end

  defp master_key do
    case Application.get_env(:aether_s3, :master_key) do
      nil -> nil
      passphrase -> SecretBox.derive_key(passphrase)
    end
  end
end
