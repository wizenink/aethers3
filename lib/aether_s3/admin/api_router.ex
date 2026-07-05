defmodule AetherS3.Admin.ApiRouter do
  @moduledoc """
  Dynamic identity management, mounted at `/admin` on the admin port and gated by
  a bootstrap bearer token (`AETHER_ADMIN_TOKEN`). Writes go through the Khepri
  control plane, so a user/key minted here replicates to every node.

      POST   /admin/users            {"name": .., "admin": bool}  -> create user
      GET    /admin/users                                         -> list users
      DELETE /admin/users/:name                                   -> delete user (+keys)
      POST   /admin/users/:name/keys                              -> mint an access key
      DELETE /admin/keys/:access_key                              -> revoke a key

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
        ControlPlane.put_user(name, admin)
        json(conn, 201, %{name: name, admin: admin})

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
    :ok = ControlPlane.delete_user(name)
    send_resp(conn, 204, "")
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
        end
    end
  end

  delete "/keys/:access_key" do
    :ok = ControlPlane.delete_key(access_key)
    send_resp(conn, 204, "")
  end

  post "/groups" do
    case read_json(conn) do
      {:ok, %{"name" => name}, conn} ->
        ControlPlane.put_group(name, [])
        json(conn, 201, %{name: name, members: []})

      _ ->
        json(conn, 400, %{error: "expected a JSON body with a \"name\""})
    end
  end

  get "/groups" do
    groups = ControlPlane.list_groups() |> Enum.map(&Map.take(&1, [:name, :members]))
    json(conn, 200, %{groups: groups})
  end

  delete "/groups/:name" do
    ControlPlane.delete_group(name)
    send_resp(conn, 204, "")
  end

  post "/groups/:name/members" do
    case read_json(conn) do
      {:ok, %{"user" => user}, conn} ->
        case ControlPlane.add_group_member(name, user) do
          :ok -> send_resp(conn, 204, "")
          {:error, :no_such_group} -> json(conn, 404, %{error: "no such group"})
        end

      _ ->
        json(conn, 400, %{error: "expected a JSON body with a \"user\""})
    end
  end

  delete "/groups/:name/members/:user" do
    case ControlPlane.remove_group_member(name, user) do
      :ok -> send_resp(conn, 204, "")
      {:error, :no_such_group} -> json(conn, 404, %{error: "no such group"})
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
        :ok = ControlPlane.put_key(access_key, user, enc)
        {:ok, access_key, secret}

      _ ->
        {:error, :no_master_key}
    end
  end

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
end
