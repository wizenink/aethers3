defmodule AetherS3.Auth.SigV4 do
  def signature(signing_key, string_to_sign) do
    hmac(signing_key, string_to_sign)
    |> Base.encode16(case: :lower)
  end

  def derive_signing_key(secret, date, region, service) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  def canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), String.trim(value)} end)
    |> Enum.sort()
    |> Enum.map_join(fn {name, value} -> "#{name}:#{value}\n" end)
  end

  def signed_headers(headers) do
    headers
    |> Enum.map(fn {name, _value} -> String.downcase(name) end)
    |> Enum.sort()
    |> Enum.join(";")
  end

  def canonical_request(method, uri, query, headers, payload_hash) do
    Enum.join(
      [method, uri, query, canonical_headers(headers), signed_headers(headers), payload_hash],
      "\n"
    )
  end

  def string_to_sign(timestamp, scope, canonical_request) do
    Enum.join(["AWS4-HMAC-SHA256", timestamp, scope, hashed_hex(canonical_request)], "\n")
  end

  defp hashed_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp hmac(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end
end
