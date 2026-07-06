defmodule AetherS3.Plug.PresignedTest do
  # NOT async: toggles :require_auth / :master_key and uses shared Khepri.
  use ExUnit.Case
  import Plug.Test

  alias AetherS3.Auth.SigV4
  alias AetherS3.Auth.SecretBox
  alias AetherS3.ControlPlane.Store
  alias AetherS3.Plug.SigV4, as: SigV4Plug

  @plug_opts SigV4Plug.init([])
  @router_opts AetherS3.Router.init([])
  @master "presign-test-master"
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

    %{alice: alice, bob: bob, bucket: "presign-#{n}", n: n}
  end

  test "a valid presigned URL authenticates as the signer" do
    conn = conn(:get, presign(:get, "/b/k", @root)) |> SigV4Plug.call(@plug_opts)
    refute conn.halted
    assert conn.assigns.identity == %{user: "root", admin: true}
  end

  test "a tampered signature is 403" do
    conn = conn(:get, tamper(presign(:get, "/b/k", @root))) |> SigV4Plug.call(@plug_opts)
    assert conn.status == 403
    assert conn.halted
  end

  test "an expired presigned URL is 403" do
    url = presign(:get, "/b/k", @root, amz_date: now_amz(-7200), expires: 900)
    conn = conn(:get, url) |> SigV4Plug.call(@plug_opts)
    assert conn.status == 403
  end

  test "an unknown access key is 403" do
    conn = conn(:get, presign(:get, "/b/k", {"AKIA_UNKNOWN", "x"})) |> SigV4Plug.call(@plug_opts)
    assert conn.status == 403
  end

  test "presigned PUT then GET work end-to-end, and authorization still applies", ctx do
    Store.create_bucket(ctx.bucket, "alice-#{ctx.n}")

    put =
      conn(:put, presign(:put, "/#{ctx.bucket}/o.txt", ctx.alice), "hello")
      |> AetherS3.Router.call(@router_opts)

    assert put.status == 200

    get =
      conn(:get, presign(:get, "/#{ctx.bucket}/o.txt", ctx.alice))
      |> AetherS3.Router.call(@router_opts)

    assert get.status == 200
    assert get.resp_body == "hello"

    # bob owns nothing here and has no grant — his presigned URL is denied.
    bob_get =
      conn(:get, presign(:get, "/#{ctx.bucket}/o.txt", ctx.bob))
      |> AetherS3.Router.call(@router_opts)

    assert bob_get.status == 403
  end

  # --- in-test presigned-URL generator (mirrors boto's query-string SigV4) ---

  defp presign(method, path, {access_key, secret}, opts \\ []) do
    expires = Keyword.get(opts, :expires, 900)
    amz_date = Keyword.get(opts, :amz_date, now_amz(0))
    date = String.slice(amz_date, 0, 8)
    region = "us-east-1"
    service = "s3"
    scope = "#{date}/#{region}/#{service}/aws4_request"

    canonical_query =
      [
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Credential", "#{access_key}/#{scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", Integer.to_string(expires)},
        {"X-Amz-SignedHeaders", "host"}
      ]
      |> Enum.map(fn {k, v} -> enc(k) <> "=" <> enc(v) end)
      |> Enum.sort()
      |> Enum.join("&")

    method_str = method |> Atom.to_string() |> String.upcase()

    canonical =
      SigV4.canonical_request(
        method_str,
        path,
        canonical_query,
        [{"host", ""}],
        "UNSIGNED-PAYLOAD"
      )

    sts = SigV4.string_to_sign(amz_date, scope, canonical)
    signature = SigV4.signature(SigV4.derive_signing_key(secret, date, region, service), sts)

    "#{path}?#{canonical_query}&X-Amz-Signature=#{signature}"
  end

  defp enc(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp now_amz(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  # Flip the last character of the signature to invalidate it.
  defp tamper(url) do
    last = String.last(url)
    String.slice(url, 0..-2//1) <> if(last == "0", do: "1", else: "0")
  end
end
