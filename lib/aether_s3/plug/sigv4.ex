defmodule AetherS3.Plug.SigV4 do
  @moduledoc """
  Validates AWS Signature V4 on incoming requests.

  Rebuilds the canonical request from the live conn using the headers the client
  listed in SignedHeaders, recomputes the signature with the stored secret, and
  compares it (constant-time) against the signature in the Authorization header.
  """
  @behaviour Plug
  import Plug.Conn
  alias AetherS3.Auth.SigV4
  alias AetherS3.S3.XML

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:aether_s3, :require_auth, true) do
      authenticate(conn)
    else
      conn
    end
  end

  defp authenticate(conn) do
    with [auth] <- get_req_header(conn, "authorization"),
         {:ok, p} <- parse_auth_header(auth),
         secret when is_binary(secret) <- secret_for(p.access_key),
         [amz_date] <- get_req_header(conn, "x-amz-date") do
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

      if Plug.Crypto.secure_compare(expected, p.signature) do
        conn
      else
        forbidden(conn)
      end
    else
      _ -> forbidden(conn)
    end
  end

  # ===== given helpers (the parsing/extraction drudgery) =====

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

  # Look up the secret for an access key, or nil if unknown.
  def secret_for(access_key) do
    Application.get_env(:aether_s3, :credentials, %{})[access_key]
  end

  # Build the {name, value} pairs for exactly the signed headers, in conn order.
  def signed_header_pairs(conn, signed_headers) do
    Enum.map(signed_headers, fn name ->
      value = conn |> get_req_header(name) |> List.first() || ""
      {name, value}
    end)
  end

  # Canonical query string: split, sort by key, rejoin. (conn.query_string is raw.)
  def canonical_query(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{URI.encode_www_form(k)}=#{URI.encode_www_form(v)}" end)
  end

  # Send a 403 with an S3 AccessDenied body and stop the pipeline.
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
