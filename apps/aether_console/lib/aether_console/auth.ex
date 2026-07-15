defmodule AetherConsole.Auth do
  @moduledoc """
  Authenticates a console operator. Strategy-selected by `AETHER_CONSOLE_AUTH`
  (config `:auth_strategy`), default `:cluster`; `:oidc` is reserved for later.

  The `:cluster` strategy verifies an access key + secret *against the cluster*: it
  SigV4-signs `GET /whoami` on the admin API and reads back the identity. The
  console never holds the master key, so it can't verify secrets itself — the
  cluster does, and tells us whether the identity is an admin.

  Phase 1 requires an admin identity (regular users have nothing to manage until
  self-service lands), so a valid but non-admin credential is rejected.
  """
  alias AetherConsole.SigV4

  @type identity :: %{user: String.t(), admin: boolean()}
  @type reason :: :invalid | :not_admin | :unavailable

  @doc "Verify a credential, returning the caller's `{user, admin}` or an error reason."
  @spec verify(String.t(), String.t()) :: {:ok, identity} | {:error, reason}
  def verify(access_key, secret) when is_binary(access_key) and is_binary(secret) do
    case strategy() do
      :cluster -> verify_cluster(access_key, secret)
      other -> raise ArgumentError, "unsupported AETHER_CONSOLE_AUTH strategy: #{inspect(other)}"
    end
  end

  # Try each configured node: a reachable node that rejects the signature is
  # decisive (:invalid — the same credential fails everywhere), an unreachable one
  # is skipped, and only all-unreachable yields :unavailable.
  defp verify_cluster(access_key, secret) do
    Enum.reduce_while(nodes(), {:error, :unavailable}, fn base, acc ->
      case whoami(base, access_key, secret) do
        {:ok, identity} -> {:halt, ensure_admin(identity)}
        {:error, :invalid} -> {:halt, {:error, :invalid}}
        {:error, :unavailable} -> {:cont, acc}
      end
    end)
  end

  defp whoami(base, access_key, secret) do
    url = String.trim_trailing(base, "/") <> "/whoami"
    headers = SigV4.headers(url, access_key, secret)

    case Req.get([url: url, headers: headers, receive_timeout: 2000, retry: false] ++ req_opts()) do
      {:ok, %{status: 200, body: body}} -> {:ok, identity_of(body)}
      {:ok, %{status: s}} when s in [401, 403] -> {:error, :invalid}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp identity_of(body) when is_binary(body), do: identity_of(Jason.decode!(body))
  # Cluster has auth off (dev): login is open, mirroring the cluster's own posture.
  defp identity_of(%{"auth_disabled" => true}), do: %{user: "auth-disabled", admin: true}
  defp identity_of(%{"user" => user, "admin" => admin}), do: %{user: user, admin: admin == true}

  defp ensure_admin(%{admin: true} = identity), do: {:ok, identity}
  defp ensure_admin(_), do: {:error, :not_admin}

  defp nodes, do: Application.get_env(:aether_console, :cluster_nodes, [])
  defp strategy, do: Application.get_env(:aether_console, :auth_strategy, :cluster)

  # Test seam: lets a test route Req through Req.Test via `plug:`.
  defp req_opts, do: Application.get_env(:aether_console, :auth_req_opts, [])
end
