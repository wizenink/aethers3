defmodule AetherS3.Plug.SigV4 do
  @moduledoc """
  Authenticates incoming requests via AWS Signature V4 and stashes the caller's
  identity in `conn.assigns[:identity]` for the authorization plug to consume.

  Outcomes:

    * valid signature       -> assign `%{user, admin}`
    * no Authorization header but a presigned URL (SigV4 in the query string) ->
      verify that and assign the signer's identity
    * no Authorization header, not presigned -> assign `:anonymous` (authorization
      decides whether the target bucket's grants permit the request)
    * bad signature / unknown key / stale date -> 403 AccessDenied, halted
    * `require_auth == false` -> assign `:auth_disabled` (the whole security
      layer is off; authorization bypasses on the same flag.
       Used by the test env and open dev servers.

  Rebuilds the canonical request from the live conn using the headers the client
  listed in SignedHeaders, recomputes the signature with the resolved secret, and
  compares it (constant-time) against the signature in the Authorization header.
  """
  @behaviour Plug
  import Plug.Conn
  alias AetherS3.Auth.SigV4
  alias AetherS3.Auth.Identity
  alias AetherS3.S3.XML

  # Reject requests whose x-amz-date is more than this far from now (replay window).
  @max_skew_seconds 300

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not Application.get_env(:aether_s3, :require_auth, true) ->
        assign(conn, :identity, :auth_disabled)

      get_req_header(conn, "authorization") != [] ->
        authenticate(conn)

      presigned?(conn) ->
        authenticate_presigned(conn)

      true ->
        assign(conn, :identity, :anonymous)
    end
  end

  defp authenticate(conn) do
    with [auth] <- get_req_header(conn, "authorization"),
         {:ok, p} <- parse_auth_header(auth),
         {:ok, identity} <- Identity.resolve(p.access_key),
         [amz_date] <- get_req_header(conn, "x-amz-date"),
         :ok <- check_date_fresh(amz_date),
         :ok <- verify_signature(conn, p, identity.secret, amz_date) do
      assign(conn, :identity, %{user: identity.user, admin: identity.admin})
    else
      _ -> forbidden(conn)
    end
  end

  defp verify_signature(conn, p, secret, amz_date) do
    payload_hash =
      conn |> get_req_header("x-amz-content-sha256") |> List.first() || "UNSIGNED-PAYLOAD"

    headers = signed_header_pairs(conn, p.signed_headers)

    canonical =
      SigV4.canonical_request(
        conn.method,
        conn.request_path,
        canonical_query(conn),
        headers,
        payload_hash
      )

    sts = SigV4.string_to_sign(amz_date, p.scope, canonical)
    signing_key = SigV4.derive_signing_key(secret, p.date, p.region, p.service)
    expected = SigV4.signature(signing_key, sts)

    if Plug.Crypto.secure_compare(expected, p.signature), do: :ok, else: :error
  end

  # --- presigned URLs (SigV4 carried in the query string) ---

  defp presigned?(conn), do: String.contains?(conn.query_string, "X-Amz-Signature=")

  defp authenticate_presigned(conn) do
    conn = fetch_query_params(conn)

    with {:ok, p} <- parse_presigned(conn.query_params),
         {:ok, identity} <- Identity.resolve(p.access_key),
         :ok <- check_presign_expiry(p.amz_date, p.expires),
         :ok <- verify_presigned(conn, p, identity.secret) do
      assign(conn, :identity, %{user: identity.user, admin: identity.admin})
    else
      _ -> forbidden(conn)
    end
  end

  defp parse_presigned(
         %{
           "X-Amz-Credential" => cred,
           "X-Amz-Date" => amz_date,
           "X-Amz-Expires" => expires,
           "X-Amz-Signature" => signature
         } = q
       ) do
    with [access_key, date, region, service, "aws4_request"] <- String.split(cred, "/"),
         {expires, ""} <- Integer.parse(expires) do
      {:ok,
       %{
         access_key: access_key,
         date: date,
         region: region,
         service: service,
         scope: "#{date}/#{region}/#{service}/aws4_request",
         amz_date: amz_date,
         expires: expires,
         signed_headers: String.split(q["X-Amz-SignedHeaders"] || "host", ";"),
         signature: signature
       }}
    else
      _ -> :error
    end
  end

  defp parse_presigned(_), do: :error

  # Valid from X-Amz-Date to X-Amz-Date + X-Amz-Expires (and not signed in the future).
  defp check_presign_expiry(amz_date, expires) do
    case parse_amz_date(amz_date) do
      {:ok, dt} ->
        diff = DateTime.diff(DateTime.utc_now(), dt)
        if diff >= -@max_skew_seconds and diff <= expires, do: :ok, else: :error

      :error ->
        :error
    end
  end

  defp verify_presigned(conn, p, secret) do
    headers = signed_header_pairs(conn, p.signed_headers)

    canonical =
      SigV4.canonical_request(
        conn.method,
        conn.request_path,
        presigned_canonical_query(conn),
        headers,
        "UNSIGNED-PAYLOAD"
      )

    sts = SigV4.string_to_sign(p.amz_date, p.scope, canonical)
    signing_key = SigV4.derive_signing_key(secret, p.date, p.region, p.service)
    expected = SigV4.signature(signing_key, sts)

    if Plug.Crypto.secure_compare(expected, p.signature), do: :ok, else: :error
  end

  # Every query param except X-Amz-Signature, sorted (already URL-encoded as sent).
  defp presigned_canonical_query(conn) do
    conn.query_string
    |> String.split("&", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "X-Amz-Signature="))
    |> Enum.sort()
    |> Enum.join("&")
  end

  # x-amz-date is basic ISO8601 ("YYYYMMDDTHHMMSSZ").
  defp check_date_fresh(amz_date) do
    case parse_amz_date(amz_date) do
      {:ok, dt} ->
        if abs(DateTime.diff(DateTime.utc_now(), dt)) <= @max_skew_seconds, do: :ok, else: :error

      :error ->
        :error
    end
  end

  defp parse_amz_date(
         <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           mi::binary-size(2), s::binary-size(2), "Z">>
       ) do
    case DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z") do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_amz_date(_), do: :error

  # Parse "AWS4-HMAC-SHA256 Credential=AK/DATE/REGION/SERVICE/aws4_request,
  #        SignedHeaders=h;h, Signature=hex" into {:ok, map} or :error.
  def parse_auth_header(value) do
    captures =
      Regex.named_captures(
        ~r/AWS4-HMAC-SHA256 Credential=(?<cred>[^,]+),\s*SignedHeaders=(?<signed>[^,]+),\s*Signature=(?<sig>[0-9a-f]+)/,
        value || ""
      )

    with %{"cred" => cred, "signed" => signed, "sig" => sig} <- captures,
         [access_key, date, region, service, "aws4_request"] <- String.split(cred, "/") do
      {:ok,
       %{
         access_key: access_key,
         date: date,
         region: region,
         service: service,
         scope: "#{date}/#{region}/#{service}/aws4_request",
         signed_headers: String.split(signed, ";"),
         signature: sig
       }}
    else
      _ -> :error
    end
  end

  def signed_header_pairs(conn, signed_headers) do
    Enum.map(signed_headers, fn name ->
      value = conn |> get_req_header(name) |> List.first() || ""
      {name, value}
    end)
  end

  def canonical_query(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{URI.encode_www_form(k)}=#{URI.encode_www_form(v)}" end)
  end

  def forbidden(conn) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(
      403,
      XML.error("AccessDenied", "Signature validation failed.", conn.request_path)
    )
    |> halt()
  end
end
