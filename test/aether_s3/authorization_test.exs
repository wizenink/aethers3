defmodule AetherS3.AuthorizationTest do
  # End-to-end authorization: auth ON, real SigV4-signed requests through the
  # full router, as different identities. NOT async (toggles global config +
  # shared Khepri).
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias AetherS3.Auth.SigV4
  alias AetherS3.Auth.SecretBox
  alias AetherS3.ControlPlane.Store

  @opts AetherS3.Router.init([])
  @master "authz-test-master"
  # root is config-seeded (:root_identities): AKIAEXAMPLE/devsecret, admin.
  @root {"AKIAEXAMPLE", "devsecret"}

  setup do
    prev_auth = Application.get_env(:aether_s3, :require_auth, true)
    prev_master = Application.get_env(:aether_s3, :master_key)
    Application.put_env(:aether_s3, :require_auth, true)
    Application.put_env(:aether_s3, :master_key, @master)

    on_exit(fn ->
      Application.put_env(:aether_s3, :require_auth, prev_auth)
      Application.put_env(:aether_s3, :master_key, prev_master)
    end)

    n = System.unique_integer([:positive])
    key = SecretBox.derive_key(@master)

    alice = {"AKIA_ALICE_#{n}", "alice-secret"}
    bob = {"AKIA_BOB_#{n}", "bob-secret"}
    Store.put_user("alice-#{n}", false)
    Store.put_key(elem(alice, 0), "alice-#{n}", SecretBox.encrypt(elem(alice, 1), key))
    Store.put_user("bob-#{n}", false)
    Store.put_key(elem(bob, 0), "bob-#{n}", SecretBox.encrypt(elem(bob, 1), key))

    %{
      alice: alice,
      bob: bob,
      alice_user: "alice-#{n}",
      bob_user: "bob-#{n}",
      bucket: "authz-#{n}",
      n: n
    }
  end

  test "owner can create, write, and read its bucket", ctx do
    assert req(:put, "/#{ctx.bucket}", ctx.alice).status == 200
    assert req(:put, "/#{ctx.bucket}/o.txt", ctx.alice, body: "hello").status == 200

    resp = req(:get, "/#{ctx.bucket}/o.txt", ctx.alice)
    assert resp.status == 200
    assert resp.resp_body == "hello"
  end

  test "another user cannot read or write a private bucket", ctx do
    seed_object(ctx)
    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 403
    assert req(:put, "/#{ctx.bucket}/x.txt", ctx.bob, body: "x").status == 403
  end

  test "anonymous cannot read a private bucket", ctx do
    seed_object(ctx)
    assert anon(:get, "/#{ctx.bucket}/o.txt").status == 403
  end

  test "admin can access another user's private bucket", ctx do
    seed_object(ctx)
    assert req(:get, "/#{ctx.bucket}/o.txt", @root).status == 200
  end

  test "public-read grants object downloads, but not writes and not listing", ctx do
    seed_object(ctx)
    Store.set_bucket_acl(ctx.bucket, "public-read")

    # object downloads (:get) are allowed for anyone
    assert anon(:get, "/#{ctx.bucket}/o.txt").status == 200
    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 200
    # but writes and *listing the bucket index* (:list) are not
    assert req(:put, "/#{ctx.bucket}/x.txt", ctx.bob, body: "x").status == 403
    assert anon(:put, "/#{ctx.bucket}/x.txt", body: "x").status == 403
    assert anon(:get, "/#{ctx.bucket}").status == 403
    assert req(:get, "/#{ctx.bucket}", ctx.bob).status == 403
  end

  test "a :list grant exposes the bucket index without granting downloads", ctx do
    seed_object(ctx)
    Store.set_bucket_grants(ctx.bucket, [%{grantee: :everyone, permission: :list}])

    assert anon(:get, "/#{ctx.bucket}").status == 200
    assert anon(:get, "/#{ctx.bucket}/o.txt").status == 403
  end

  test "public-read-write grants cross-user and anonymous object writes", ctx do
    assert req(:put, "/#{ctx.bucket}", ctx.alice).status == 200
    Store.set_bucket_acl(ctx.bucket, "public-read-write")

    assert req(:put, "/#{ctx.bucket}/x.txt", ctx.bob, body: "x").status == 200
    assert anon(:put, "/#{ctx.bucket}/y.txt", body: "y").status == 200
  end

  test "only the owner or admin can delete a bucket", ctx do
    assert req(:put, "/#{ctx.bucket}", ctx.alice).status == 200
    # Even wide-open ACL must not let a stranger drop the bucket.
    Store.set_bucket_acl(ctx.bucket, "public-read-write")

    assert req(:delete, "/#{ctx.bucket}", ctx.bob).status == 403
    assert req(:delete, "/#{ctx.bucket}", ctx.alice).status == 204
  end

  test "x-amz-acl on create sets the canned ACL", ctx do
    assert req(:put, "/#{ctx.bucket}", ctx.alice, headers: [{"x-amz-acl", "public-read"}]).status ==
             200

    # canned public-read is now sugar for an :everyone :get grant (download only)
    assert %{grants: [%{grantee: :everyone, permission: :get}]} = Store.get_bucket(ctx.bucket)
  end

  test "a nonexistent bucket is 404, not 403 (no existence leak)", ctx do
    assert req(:get, "/nope-#{ctx.n}/o.txt", ctx.bob).status == 404
  end

  test "owner can share a private bucket with a specific user", ctx do
    seed_object(ctx)
    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 403

    Store.set_bucket_grants(ctx.bucket, [%{grantee: {:user, ctx.bob_user}, permission: :read}])

    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 200
    # read-only grant: still can't write
    assert req(:put, "/#{ctx.bucket}/x.txt", ctx.bob, body: "x").status == 403
  end

  test "a group grant lets members in, non-members stay out", ctx do
    seed_object(ctx)
    group = "grp-#{ctx.n}"
    Store.put_group(group, [ctx.bob_user])
    Store.set_bucket_grants(ctx.bucket, [%{grantee: {:group, group}, permission: :full}])

    # bob is a member -> full access
    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 200
    assert req(:put, "/#{ctx.bucket}/y.txt", ctx.bob, body: "y").status == 200

    # anonymous is in no group -> denied
    assert anon(:get, "/#{ctx.bucket}/o.txt").status == 403
  end

  test "owner self-serves a grant via PUT ?acl (x-amz-grant-read)", ctx do
    seed_object(ctx)
    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 403

    grant =
      req(:put, "/#{ctx.bucket}?acl", ctx.alice,
        headers: [{"x-amz-grant-read", ~s(id="#{ctx.bob_user}")}]
      )

    assert grant.status == 200

    assert req(:get, "/#{ctx.bucket}/o.txt", ctx.bob).status == 200
    # read-only grant: still no write
    assert req(:put, "/#{ctx.bucket}/x.txt", ctx.bob, body: "x").status == 403
  end

  test "a non-owner cannot change grants via PUT ?acl", ctx do
    seed_object(ctx)

    resp =
      req(:put, "/#{ctx.bucket}?acl", ctx.bob,
        headers: [{"x-amz-grant-full-control", ~s(id="#{ctx.bob_user}")}]
      )

    assert resp.status == 403
  end

  # --- helpers ---

  defp seed_object(ctx) do
    assert req(:put, "/#{ctx.bucket}", ctx.alice).status == 200
    assert req(:put, "/#{ctx.bucket}/o.txt", ctx.alice, body: "hello").status == 200
  end

  defp req(method, path, {ak, secret}, opts \\ []) do
    conn(method, path, Keyword.get(opts, :body, ""))
    |> put_headers(Keyword.get(opts, :headers, []))
    |> sign(ak, secret)
    |> AetherS3.Router.call(@opts)
  end

  defp anon(method, path, opts \\ []) do
    conn(method, path, Keyword.get(opts, :body, ""))
    |> put_headers(Keyword.get(opts, :headers, []))
    |> AetherS3.Router.call(@opts)
  end

  defp put_headers(conn, headers),
    do: Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

  # Minimal valid SigV4 signer (host reads as "" for a test conn; see sigv4 plug test).
  defp sign(conn, access_key, secret) do
    amz_date = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    date = String.slice(amz_date, 0, 8)
    region = "us-east-1"
    service = "s3"
    payload_hash = "UNSIGNED-PAYLOAD"

    conn =
      conn
      |> put_req_header("x-amz-date", amz_date)
      |> put_req_header("x-amz-content-sha256", payload_hash)

    signed = ["host", "x-amz-content-sha256", "x-amz-date"]
    headers = Enum.map(signed, fn h -> {h, conn |> get_req_header(h) |> List.first() || ""} end)
    query = AetherS3.Plug.SigV4.canonical_query(conn)

    canonical =
      SigV4.canonical_request(conn.method, conn.request_path, query, headers, payload_hash)

    scope = "#{date}/#{region}/#{service}/aws4_request"
    sts = SigV4.string_to_sign(amz_date, scope, canonical)
    signature = SigV4.signature(SigV4.derive_signing_key(secret, date, region, service), sts)

    put_req_header(
      conn,
      "authorization",
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, " <>
        "SignedHeaders=#{Enum.join(signed, ";")}, Signature=#{signature}"
    )
  end
end
