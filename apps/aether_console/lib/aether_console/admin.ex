defmodule AetherConsole.Admin do
  @moduledoc """
  Client for the cluster's admin API (`/admin/*` on the admin port), bearer-token
  gated. Reads and writes users / keys / groups / buckets — any node's admin API
  answers for the whole cluster (writes go through the CP), so we hit the first
  configured node.

  The console holds the cluster's admin token (`AETHER_CONSOLE_ADMIN_TOKEN`). Reads
  return `{:ok, list}` or `{:error, reason}`; writes return `{:ok, body} | :ok` or
  `{:error, reason}`, where reason is `:no_token` (console has no token configured),
  `:unauthorized` (token rejected), `:conflict` (already exists / not empty),
  `:not_found`, `:invalid`, or `:unavailable` (no node reachable).
  """

  # ── reads ──────────────────────────────────────────────────────────────────
  def users, do: list("/admin/users", "users")
  def keys, do: list("/admin/keys", "keys")
  def groups, do: list("/admin/groups", "groups")
  def buckets, do: list("/admin/buckets", "buckets")

  # ── writes ─────────────────────────────────────────────────────────────────
  def create_user(name, admin?), do: post("/admin/users", %{name: name, admin: admin?})
  def delete_user(name), do: delete("/admin/users/#{enc(name)}")

  # Returns {:ok, %{"access_key" => .., "secret_key" => ..}} — the secret is shown once.
  def mint_key(user), do: post("/admin/users/#{enc(user)}/keys", %{})
  def revoke_key(access_key), do: delete("/admin/keys/#{enc(access_key)}")

  def create_group(name), do: post("/admin/groups", %{name: name})
  def delete_group(name), do: delete("/admin/groups/#{enc(name)}")
  def add_member(group, user), do: post("/admin/groups/#{enc(group)}/members", %{user: user})

  def remove_member(group, user),
    do: delete("/admin/groups/#{enc(group)}/members/#{enc(user)}")

  def create_bucket(name), do: post("/admin/buckets", %{name: name})
  def delete_bucket(name), do: delete("/admin/buckets/#{enc(name)}")

  # ── HTTP core ────────────────────────────────────────────────────────────────
  defp list(path, key) do
    case request(:get, path, nil) do
      {:ok, _status, body} -> {:ok, extract(body, key)}
      err -> err
    end
  end

  defp post(path, body) do
    case request(:post, path, body) do
      {:ok, _status, body} -> {:ok, body}
      err -> err
    end
  end

  defp delete(path) do
    case request(:delete, path, nil) do
      {:ok, _status, _body} -> :ok
      err -> err
    end
  end

  # One place that knows about tokens, base URL, and status → reason mapping.
  defp request(method, path, body) do
    with base when is_binary(base) <- base_url(),
         tok when is_binary(tok) and tok != "" <- token() do
      opts =
        [method: method, url: String.trim_trailing(base, "/") <> path]
        |> put_auth(tok)
        |> put_body(body)

      case Req.request(opts) do
        {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, s, b}
        {:ok, %{status: 400}} -> {:error, :invalid}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: 409}} -> {:error, :conflict}
        _ -> {:error, :unavailable}
      end
    else
      _ -> {:error, :no_token}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp put_auth(opts, tok),
    do: opts ++ [auth: {:bearer, tok}, receive_timeout: 2000, retry: false]

  defp put_body(opts, nil), do: opts
  defp put_body(opts, body), do: opts ++ [json: body]

  defp extract(body, key) when is_map(body), do: Map.get(body, key, [])
  defp extract(body, key) when is_binary(body), do: Map.get(Jason.decode!(body), key, [])

  defp enc(segment), do: URI.encode(to_string(segment), &URI.char_unreserved?/1)

  defp base_url do
    case Application.get_env(:aether_console, :cluster_nodes, []) do
      [url | _] -> url
      _ -> nil
    end
  end

  defp token, do: Application.get_env(:aether_console, :admin_token)
end
