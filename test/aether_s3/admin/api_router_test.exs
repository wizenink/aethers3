defmodule AetherS3.Admin.ApiRouterTest do
  # NOT async: toggles :admin_token / :master_key and writes to shared Khepri.
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias AetherS3.ControlPlane.Store
  alias AetherS3.Auth.Identity

  @opts AetherS3.AdminRouter.init([])
  @token "test-admin-token"

  setup do
    prev_token = Application.get_env(:aether_s3, :admin_token)
    prev_master = Application.get_env(:aether_s3, :master_key)
    Application.put_env(:aether_s3, :admin_token, @token)
    Application.put_env(:aether_s3, :master_key, "admin-test-master")

    on_exit(fn ->
      Application.put_env(:aether_s3, :admin_token, prev_token)
      Application.put_env(:aether_s3, :master_key, prev_master)
    end)

    :ok
  end

  defp call(conn), do: AetherS3.AdminRouter.call(conn, @opts)

  defp authed(method, path, body \\ nil) do
    conn = if body, do: conn(method, path, JSON.encode!(body)), else: conn(method, path)

    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> call()
  end

  test "probe endpoints stay open (no token)" do
    assert conn(:get, "/health") |> call() |> Map.get(:status) == 200
  end

  test "management endpoints require the bearer token" do
    assert conn(:get, "/admin/users") |> call() |> Map.get(:status) == 401

    wrong =
      conn(:get, "/admin/users") |> put_req_header("authorization", "Bearer nope") |> call()

    assert wrong.status == 401
  end

  test "with no token configured the API is disabled" do
    Application.put_env(:aether_s3, :admin_token, nil)

    resp =
      conn(:get, "/admin/users")
      |> put_req_header("authorization", "Bearer anything")
      |> call()

    assert resp.status == 401
  end

  test "create, list, and delete a user" do
    name = "api-#{System.unique_integer([:positive])}"
    assert authed(:post, "/admin/users", %{name: name, admin: false}).status == 201

    list = authed(:get, "/admin/users")
    assert list.status == 200
    assert %{"users" => users} = JSON.decode!(list.resp_body)
    assert Enum.any?(users, &(&1["name"] == name))

    assert authed(:delete, "/admin/users/#{name}").status == 204
    assert Store.get_user(name) == nil
  end

  test "a minted key round-trips through the resolver (it can authenticate)" do
    name = "api-key-#{System.unique_integer([:positive])}"
    authed(:post, "/admin/users", %{name: name, admin: false})

    resp = authed(:post, "/admin/users/#{name}/keys")
    assert resp.status == 201
    %{"access_key" => ak, "secret_key" => sk} = JSON.decode!(resp.resp_body)

    # The resolver decrypts the stored secret back to exactly what we returned.
    assert {:ok, %{user: ^name, secret: ^sk}} = Identity.resolve(ak)

    assert authed(:delete, "/admin/keys/#{ak}").status == 204
    assert Identity.resolve(ak) == :error
  end

  test "deleting a user cascades its keys" do
    name = "api-cascade-#{System.unique_integer([:positive])}"
    authed(:post, "/admin/users", %{name: name})
    %{"access_key" => ak} = authed(:post, "/admin/users/#{name}/keys").resp_body |> JSON.decode!()

    authed(:delete, "/admin/users/#{name}")
    assert Store.get_key(ak) == nil
  end

  test "minting a key for an unknown user is 404" do
    ghost = "ghost-#{System.unique_integer([:positive])}"
    assert authed(:post, "/admin/users/#{ghost}/keys").status == 404
  end

  test "minting without a master key is 503" do
    Application.put_env(:aether_s3, :master_key, nil)
    name = "nomaster-#{System.unique_integer([:positive])}"
    authed(:post, "/admin/users", %{name: name})
    assert authed(:post, "/admin/users/#{name}/keys").status == 503
  end

  test "create a group, add and remove members, delete it" do
    g = "grp-#{System.unique_integer([:positive])}"
    assert authed(:post, "/admin/groups", %{name: g}).status == 201

    list = authed(:get, "/admin/groups")
    assert %{"groups" => groups} = JSON.decode!(list.resp_body)
    assert Enum.any?(groups, &(&1["name"] == g))

    assert authed(:post, "/admin/groups/#{g}/members", %{user: "bob"}).status == 204
    assert AetherS3.ControlPlane.Store.groups_of("bob") |> Enum.member?(g)

    assert authed(:delete, "/admin/groups/#{g}/members/bob").status == 204
    refute AetherS3.ControlPlane.Store.groups_of("bob") |> Enum.member?(g)

    assert authed(:delete, "/admin/groups/#{g}").status == 204
    assert AetherS3.ControlPlane.Store.get_group(g) == nil
  end

  test "adding a member to a missing group is 404" do
    g = "ghost-grp-#{System.unique_integer([:positive])}"
    assert authed(:post, "/admin/groups/#{g}/members", %{user: "bob"}).status == 404
  end

  test "group endpoints require the bearer token" do
    assert conn(:get, "/admin/groups") |> call() |> Map.get(:status) == 401
  end
end
