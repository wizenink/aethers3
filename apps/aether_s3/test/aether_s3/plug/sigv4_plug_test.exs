defmodule AetherS3.Plug.SigV4Test do
  # NOT async: toggles the global :require_auth flag.
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias AetherS3.Auth.SigV4
  alias AetherS3.Plug.SigV4, as: Plug

  @opts Plug.init([])

  setup do
    prev = Application.get_env(:aether_s3, :require_auth, true)
    Application.put_env(:aether_s3, :require_auth, true)
    on_exit(fn -> Application.put_env(:aether_s3, :require_auth, prev) end)
    :ok
  end

  test "auth disabled assigns :auth_disabled and does not halt" do
    Application.put_env(:aether_s3, :require_auth, false)
    conn = Plug.call(conn(:get, "/bucket"), @opts)
    refute conn.halted
    assert conn.assigns.identity == :auth_disabled
  end

  test "no Authorization header is anonymous, not halted" do
    conn = Plug.call(conn(:get, "/bucket"), @opts)
    refute conn.halted
    assert conn.assigns.identity == :anonymous
  end

  test "a garbage Authorization header is 403 + halted" do
    conn =
      conn(:get, "/bucket")
      |> put_req_header("authorization", "not a real sigv4 header")
      |> Plug.call(@opts)

    assert conn.status == 403
    assert conn.halted
  end

  test "a valid signature assigns the resolved identity" do
    conn =
      conn(:get, "/bucket")
      |> sign("AKIAEXAMPLE", "devsecret")
      |> Plug.call(@opts)

    refute conn.halted
    assert conn.assigns.identity == %{user: "root", admin: true}
  end

  test "a valid signature with the wrong secret is 403" do
    conn =
      conn(:get, "/bucket")
      |> sign("AKIAEXAMPLE", "not-the-real-secret")
      |> Plug.call(@opts)

    assert conn.status == 403
    assert conn.halted
  end

  test "an unknown access key is 403" do
    conn =
      conn(:get, "/bucket")
      |> sign("AKIA_UNKNOWN", "whatever")
      |> Plug.call(@opts)

    assert conn.status == 403
  end

  test "a stale date is 403 even with an otherwise valid signature" do
    stale = amz_date(-600)

    conn =
      conn(:get, "/bucket")
      |> sign("AKIAEXAMPLE", "devsecret", amz_date: stale)
      |> Plug.call(@opts)

    assert conn.status == 403
    assert conn.halted
  end

  # --- in-test SigV4 signer (mirrors what a client / aws-cli does) ---

  defp sign(conn, access_key, secret, opts \\ []) do
    amz_date = Keyword.get(opts, :amz_date, amz_date(0))
    date = String.slice(amz_date, 0, 8)
    region = "us-east-1"
    service = "s3"
    payload_hash = "UNSIGNED-PAYLOAD"

    # NB: the "host" header can't be set via put_req_header (Plug stores it in
    # conn.host); the plug reads it via get_req_header, which is "" for a test
    # conn — so we sign with that same empty value. The `|| ""` mirrors the
    # plug's own signed_header_pairs fallback exactly.
    conn =
      conn
      |> put_req_header("x-amz-date", amz_date)
      |> put_req_header("x-amz-content-sha256", payload_hash)

    signed = ["host", "x-amz-content-sha256", "x-amz-date"]
    headers = Enum.map(signed, fn h -> {h, conn |> get_req_header(h) |> List.first() || ""} end)

    canonical =
      SigV4.canonical_request(conn.method, conn.request_path, "", headers, payload_hash)

    scope = "#{date}/#{region}/#{service}/aws4_request"
    sts = SigV4.string_to_sign(amz_date, scope, canonical)
    signing_key = SigV4.derive_signing_key(secret, date, region, service)
    signature = SigV4.signature(signing_key, sts)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, " <>
        "SignedHeaders=#{Enum.join(signed, ";")}, Signature=#{signature}"

    put_req_header(conn, "authorization", auth)
  end

  defp amz_date(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
