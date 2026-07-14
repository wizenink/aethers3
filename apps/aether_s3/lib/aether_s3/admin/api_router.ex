defmodule AetherS3.Admin.ApiRouter do
  @moduledoc """
  Dynamic identity management, mounted at `/admin` on the admin port and gated by
  a bootstrap bearer token (`AETHER_ADMIN_TOKEN`). Writes go through the Khepri
  control plane, so a user/key minted here replicates to every node.

      POST   /admin/users            {"name": .., "admin": bool}  -> create user
      GET    /admin/users                                         -> list users
      DELETE /admin/users/:name                                   -> delete user (+keys)
      POST   /admin/users/:name/keys                              -> mint an access key
      GET    /admin/keys                                          -> list keys
      DELETE /admin/keys/:access_key                              -> revoke a key
      POST   /admin/groups           {"name": ..}                 -> create group
      GET    /admin/groups                                        -> list groups
      DELETE /admin/groups/:name                                  -> delete group
      POST   /admin/groups/:name/members  {"user": ..}            -> add member
      DELETE /admin/groups/:name/members/:user                    -> remove member
      GET    /admin/buckets                                       -> list buckets
      POST   /admin/buckets          {"name": ..}                 -> create bucket
      DELETE /admin/buckets/:name                                 -> delete bucket (empty only)

  With no token configured the whole API is disabled (every request is 401), so a
  node can't have identities minted against it until an operator sets a token.
  """
  use Plug.Router
  alias AetherS3.ControlPlane.Store, as: ControlPlane
  alias AetherS3.Auth.SecretBox

  plug(:require_token)
  plug(:match)
  plug(:dispatch)

  post "/users" do
    case read_json(conn) do
      {:ok, %{"name" => name} = body, conn} ->
        admin = Map.get(body, "admin", false) == true

        case ControlPlane.put_user(name, admin) do
          :ok -> json(conn, 201, %{name: name, admin: admin})
          {:error, :unavailable} -> unavailable(conn)
        end

      _ ->
        json(conn, 400, %{error: "expected a JSON body with a \"name\""})
    end
  end

  get "/users" do
    users = ControlPlane.list_users() |> Enum.map(&Map.take(&1, [:name, :admin]))
    json(conn, 200, %{users: users})
  end

  delete "/users/:name" do
    # Orphaned buckets (owner now gone) become admin-only, which is safe.
    reply_204(conn, ControlPlane.delete_user(name))
  end

  post "/users/:name/keys" do
    cond do
      is_nil(ControlPlane.get_user(name)) ->
        json(conn, 404, %{error: "no such user"})

      true ->
        case mint_key(name) do
          {:ok, access_key, secret} ->
            # The secret is shown exactly once — it's stored only encrypted.
            json(conn, 201, %{access_key: access_key, secret_key: secret})

          {:error, :no_master_key} ->
            json(conn, 503, %{error: "AETHER_MASTER_KEY not configured"})

          {:error, :unavailable} ->
            unavailable(conn)
        end
    end
  end

  delete "/keys/:access_key" do
    reply_204(conn, ControlPlane.delete_key(access_key))
  end

  post "/groups" do
    case read_json(conn) do
      {:ok, %{"name" => name}, conn} ->
        case ControlPlane.put_group(name, []) do
          :ok -> json(conn, 201, %{name: name, members: []})
          {:error, :unavailable} -> unavailable(conn)
        end

      _ ->
        json(conn, 400, %{error: "expected a JSON body with a \"name\""})
    end
  end

  get "/groups" do
    groups = ControlPlane.list_groups() |> Enum.map(&Map.take(&1, [:name, :members]))
    json(conn, 200, %{groups: groups})
  end

  get "/keys" do
    keys = ControlPlane.list_keys() |> Enum.map(&key_view/1)
    json(conn, 200, %{keys: keys})
  end

  get "/buckets" do
    buckets = ControlPlane.list_buckets() |> Enum.map(&bucket_view/1)
    json(conn, 200, %{buckets: buckets})
  end

  post "/buckets" do
    case read_json(conn) do
      {:ok, %{"name" => name}, conn} ->
        cond do
          not valid_bucket_name?(name) ->
            json(conn, 400, %{error: "invalid bucket name"})

          ControlPlane.bucket_exists?(name) ->
            json(conn, 409, %{error: "bucket already exists"})

          true ->
            # Console-created buckets are admin-owned (owner nil) until an ACL is set.
            case ControlPlane.create_bucket(name, nil) do
              :ok -> json(conn, 201, %{name: name})
              {:error, :unavailable} -> unavailable(conn)
            end
        end

      _ ->
        json(conn, 400, %{error: "expected a JSON body with a \"name\""})
    end
  end

  delete "/buckets/:name" do
    case ControlPlane.delete_bucket(name) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_empty} -> json(conn, 409, %{error: "bucket not empty"})
      {:error, :unavailable} -> unavailable(conn)
    end
  end

  delete "/groups/:name" do
    reply_204(conn, ControlPlane.delete_group(name))
  end

  post "/groups/:name/members" do
    case read_json(conn) do
      {:ok, %{"user" => user}, conn} ->
        case ControlPlane.add_group_member(name, user) do
          :ok -> send_resp(conn, 204, "")
          {:error, :no_such_group} -> json(conn, 404, %{error: "no such group"})
          {:error, :unavailable} -> unavailable(conn)
        end

      _ ->
        json(conn, 400, %{error: "expected a JSON body with a \"user\""})
    end
  end

  delete "/groups/:name/members/:user" do
    case ControlPlane.remove_group_member(name, user) do
      :ok -> send_resp(conn, 204, "")
      {:error, :no_such_group} -> json(conn, 404, %{error: "no such group"})
      {:error, :unavailable} -> unavailable(conn)
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp require_token(conn, _opts) do
    token = Application.get_env(:aether_s3, :admin_token)
    presented = bearer(conn)

    if is_binary(token) and token != "" and is_binary(presented) and
         Plug.Crypto.secure_compare(presented, token) do
      conn
    else
      conn |> json(401, %{error: "unauthorized"}) |> halt()
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp mint_key(user) do
    case Application.get_env(:aether_s3, :master_key) do
      m when is_binary(m) and m != "" ->
        access_key = "AKIA" <> (:crypto.strong_rand_bytes(12) |> Base.encode32(padding: false))
        secret = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        enc = SecretBox.encrypt(secret, SecretBox.derive_key(m))

        case ControlPlane.put_key(access_key, user, enc) do
          :ok -> {:ok, access_key, secret}
          {:error, :unavailable} -> {:error, :unavailable}
        end

      _ ->
        {:error, :no_master_key}
    end
  end

  # S3 DNS-style bucket naming: 3–63 chars, lowercase alnum / hyphen / dot,
  # must start and end alphanumeric. Conservative on the create path (the S3 PUT
  # route is permissive; the console shouldn't mint names clients can't address).
  defp valid_bucket_name?(name) when is_binary(name) do
    String.length(name) in 3..63 and name =~ ~r/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/
  end

  defp valid_bucket_name?(_), do: false

  defp reply_204(conn, :ok), do: send_resp(conn, 204, "")
  defp reply_204(conn, {:error, :unavailable}), do: unavailable(conn)

  defp unavailable(conn), do: json(conn, 503, %{error: "control plane unavailable"})

  defp read_json(conn) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, decoded} <- JSON.decode(body) do
      {:ok, decoded, conn}
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end

  # ── JSON-friendly views (built-in JSON can't encode DateTime or grantee tuples) ──
  defp key_view(k), do: %{access_key: k.name, user: k[:user], created_at: iso(k[:created_at])}

  defp bucket_view(b) do
    %{
      name: b.name,
      owner: b[:owner],
      created_at: iso(b[:created_at]),
      grants: Enum.map(b[:grants] || [], &grant_view/1),
      scoped_grants:
        Enum.map(b[:scoped_grants] || [], fn e ->
          %{scope: e.scope, grants: Enum.map(e.grants, &grant_view/1)}
        end)
    }
  end

  defp grant_view(%{grantee: g, permission: p}),
    do: %{grantee: grantee(g), permission: to_string(p)}

  defp grantee(:everyone), do: "everyone"
  defp grantee({:user, n}), do: "user:" <> n
  defp grantee({:group, n}), do: "group:" <> n

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil
end
