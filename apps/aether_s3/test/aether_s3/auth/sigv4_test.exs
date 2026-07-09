defmodule AetherS3.Auth.SigV4Test do
  use ExUnit.Case, async: true

  alias AetherS3.Auth.SigV4

  test "derive_signing_key matches the AWS-documented reference vector" do
    key =
      SigV4.derive_signing_key(
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "20150830",
        "us-east-1",
        "iam"
      )

    assert Base.encode16(key, case: :lower) ==
             "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
  end

  test "canonical_headers lowercases names, trims values, sorts, newline-terminates" do
    headers = [{"X-Amz-Date", "20250625T120000Z"}, {"Host", "  s3.example.com  "}]

    assert SigV4.canonical_headers(headers) ==
             "host:s3.example.com\nx-amz-date:20250625T120000Z\n"
  end

  test "signed_headers are lowercased, sorted, and semicolon-joined" do
    headers = [{"X-Amz-Date", "x"}, {"Host", "y"}]
    assert SigV4.signed_headers(headers) == "host;x-amz-date"
  end

  test "full chain produces the signature cross-checked against an independent impl" do
    headers = [{"Host", "s3.example.com"}, {"X-Amz-Date", "20250625T120000Z"}]

    canonical =
      SigV4.canonical_request(
        "GET",
        "/photos/cat.jpg",
        "max-keys=2&prefix=c",
        headers,
        "UNSIGNED-PAYLOAD"
      )

    sts =
      SigV4.string_to_sign("20250625T120000Z", "20250625/us-east-1/s3/aws4_request", canonical)

    signing_key = SigV4.derive_signing_key("SECRET123", "20250625", "us-east-1", "s3")

    assert SigV4.signature(signing_key, sts) ==
             "8d462727fe1df5feb05a8dddcc1c480a615c3a186780ecd3448059530ab56d7c"
  end

  test "a tampered string-to-sign produces a different signature" do
    sk = SigV4.derive_signing_key("SECRET123", "20250625", "us-east-1", "s3")
    refute SigV4.signature(sk, "a") == SigV4.signature(sk, "b")
  end
end
