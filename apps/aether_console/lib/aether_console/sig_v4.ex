defmodule AetherConsole.SigV4 do
  @moduledoc """
  Minimal AWS Signature V4 request signer — enough for the console to authenticate
  to the cluster *as a user* (currently a bodyless `GET /whoami`).

  The console is a separate release and can't depend on `aether_s3`, so this mirrors
  the algorithm in `AetherS3.Auth.SigV4`; the cluster verifies with the same steps.
  The `host` header is part of the signature but the HTTP client sets it, so it's
  signed here with the value the client will send (derived from the URL) and not
  returned as a header to add.
  """

  @region "us-east-1"
  @service "s3"
  @payload_hash "UNSIGNED-PAYLOAD"

  @doc """
  Headers to add to a bodyless `GET url`, signed with `access_key`/`secret`:
  `authorization`, `x-amz-date`, `x-amz-content-sha256`. `now` is injectable for
  tests.
  """
  @spec headers(String.t(), String.t(), String.t(), DateTime.t()) :: [{String.t(), String.t()}]
  def headers(url, access_key, secret, now \\ DateTime.utc_now()) do
    uri = URI.parse(url)
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = String.slice(amz_date, 0, 8)

    # Signed headers, as {name, value} pairs. Must include the value the HTTP client
    # will actually send for host, or the server's recomputed signature won't match.
    signed = [
      {"host", host_header(uri)},
      {"x-amz-content-sha256", @payload_hash},
      {"x-amz-date", amz_date}
    ]

    canonical = canonical_request("GET", uri.path || "/", "", signed, @payload_hash)
    scope = "#{date}/#{@region}/#{@service}/aws4_request"
    sts = string_to_sign(amz_date, scope, canonical)
    signing_key = derive_signing_key(secret, date, @region, @service)
    signature = signature(signing_key, sts)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, " <>
        "SignedHeaders=#{signed_header_names(signed)}, Signature=#{signature}"

    [
      {"authorization", auth},
      {"x-amz-date", amz_date},
      {"x-amz-content-sha256", @payload_hash}
    ]
  end

  # host:port, dropping the port when it's the scheme default (HTTP/1.1 does the same).
  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port in [nil, default_port(scheme)], do: host, else: "#{host}:#{port}"
  end

  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  # ── algorithm (mirrors AetherS3.Auth.SigV4) ──────────────────────────────────

  defp canonical_request(method, uri, query, headers, payload_hash) do
    Enum.join(
      [
        method,
        uri,
        query,
        canonical_headers(headers),
        signed_header_names(headers),
        payload_hash
      ],
      "\n"
    )
  end

  defp canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), String.trim(value)} end)
    |> Enum.sort()
    |> Enum.map_join(fn {name, value} -> "#{name}:#{value}\n" end)
  end

  defp signed_header_names(headers) do
    headers
    |> Enum.map(fn {name, _} -> String.downcase(name) end)
    |> Enum.sort()
    |> Enum.join(";")
  end

  defp string_to_sign(timestamp, scope, canonical_request) do
    Enum.join(["AWS4-HMAC-SHA256", timestamp, scope, hashed_hex(canonical_request)], "\n")
  end

  defp derive_signing_key(secret, date, region, service) do
    ("AWS4" <> secret) |> hmac(date) |> hmac(region) |> hmac(service) |> hmac("aws4_request")
  end

  defp signature(signing_key, sts), do: signing_key |> hmac(sts) |> Base.encode16(case: :lower)
  defp hashed_hex(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
