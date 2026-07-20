defmodule AetherS3.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AetherS3.Replication.Coordinator
  alias AetherS3.Storage.Multipart

  @opts AetherS3.Router.init([])

  defp call(conn), do: AetherS3.Router.call(conn, @opts)

  defp text_put(path, body) do
    conn(:put, path, body)
    |> put_req_header("content-type", "text/plain")
    |> call()
  end

  setup do
    # Unique bucket per test keeps the shared CubDB stores isolated.
    {:ok, bucket: "test-#{System.unique_integer([:positive])}"}
  end

  test "object lifecycle: create bucket, put, get, head, delete", %{bucket: bucket} do
    assert call(conn(:put, "/#{bucket}")).status == 200

    put = text_put("/#{bucket}/hello.txt", "hello world")
    assert put.status == 200
    assert [_etag] = get_resp_header(put, "etag")

    get = call(conn(:get, "/#{bucket}/hello.txt"))
    assert get.status == 200
    assert get.resp_body == "hello world"
    assert get_resp_header(get, "content-type") == ["text/plain"]

    head = call(conn(:head, "/#{bucket}/hello.txt"))
    assert head.status == 200
    assert get_resp_header(head, "content-length") == ["11"]

    assert call(conn(:delete, "/#{bucket}/hello.txt")).status == 204
    assert call(conn(:get, "/#{bucket}/hello.txt")).status == 404
  end

  test "aws-chunked upload is de-framed, not stored verbatim", %{bucket: bucket} do
    assert call(conn(:put, "/#{bucket}")).status == 200

    data = :crypto.strong_rand_bytes(20_000)
    framed = aws_chunk(data, 8192)
    # Sanity: the wire body is larger than the object (that's the framing we must strip).
    assert byte_size(framed) > byte_size(data)

    put =
      conn(:put, "/#{bucket}/blob.bin", framed)
      |> put_req_header("content-encoding", "aws-chunked")
      |> put_req_header("x-amz-content-sha256", "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
      |> put_req_header("x-amz-decoded-content-length", Integer.to_string(byte_size(data)))
      |> call()

    assert put.status == 200
    # etag is the md5 of the *decoded* object, not the framed wire bytes.
    expected_etag = data |> :erlang.md5() |> Base.encode16(case: :lower)
    assert get_resp_header(put, "etag") == [~s("#{expected_etag}")]

    get = call(conn(:get, "/#{bucket}/blob.bin"))
    assert get.status == 200
    assert get.resp_body == data

    # HEAD reports the stored size — the decoded length, not the framed wire size.
    head = call(conn(:head, "/#{bucket}/blob.bin"))
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(data))]
  end

  # Minimal unsigned aws-chunked framer for tests (mirrors what SDK clients send).
  defp aws_chunk(data, size) do
    body =
      data
      |> chunks(size)
      |> Enum.map_join(fn part -> "#{Integer.to_string(byte_size(part), 16)}\r\n#{part}\r\n" end)

    body <> "0\r\nx-amz-checksum-crc32:AAAAAA==\r\n\r\n"
  end

  defp chunks(bin, n) when byte_size(bin) <= n, do: [bin]

  defp chunks(bin, n) do
    <<head::binary-size(n), rest::binary>> = bin
    [head | chunks(rest, n)]
  end

  test "CopyObject: x-amz-copy-source deep-copies a regular object", %{bucket: bucket} do
    assert call(conn(:put, "/#{bucket}")).status == 200
    body = "the quick brown fox jumps over the lazy dog"
    assert text_put("/#{bucket}/src.txt", body).status == 200

    copy =
      conn(:put, "/#{bucket}/dst.txt")
      |> put_req_header("x-amz-copy-source", "/#{bucket}/src.txt")
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<CopyObjectResult>"
    etag = body |> :erlang.md5() |> Base.encode16(case: :lower)
    assert copy.resp_body =~ etag

    get = call(conn(:get, "/#{bucket}/dst.txt"))
    assert get.status == 200
    assert get.resp_body == body

    # Deep copy: the copy owns its own blob, so deleting the source can't affect it.
    assert call(conn(:delete, "/#{bucket}/src.txt")).status == 204
    assert call(conn(:get, "/#{bucket}/dst.txt")).resp_body == body
  end

  test "CopyObject: missing source is 404 NoSuchKey", %{bucket: bucket} do
    assert call(conn(:put, "/#{bucket}")).status == 200

    copy =
      conn(:put, "/#{bucket}/dst.txt")
      |> put_req_header("x-amz-copy-source", "/#{bucket}/ghost.txt")
      |> call()

    assert copy.status == 404
    assert copy.resp_body =~ "NoSuchKey"
  end

  test "CopyObject: UploadPartCopy (partNumber) is 501, not a 0-byte part", %{bucket: bucket} do
    assert call(conn(:put, "/#{bucket}")).status == 200

    resp =
      conn(:put, "/#{bucket}/dst?partNumber=1&uploadId=abc")
      |> put_req_header("x-amz-copy-source", "/#{bucket}/src")
      |> call()

    assert resp.status == 501
    assert resp.resp_body =~ "NotImplemented"
  end

  describe "read-time integrity verification (AETHER_VERIFY_READS)" do
    setup do
      prev = Application.get_env(:aether_s3, :verify_reads)
      Application.put_env(:aether_s3, :verify_reads, true)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:aether_s3, :verify_reads)
          v -> Application.put_env(:aether_s3, :verify_reads, v)
        end
      end)

      :ok
    end

    test "an intact object streams normally under verification", %{bucket: bucket} do
      assert call(conn(:put, "/#{bucket}")).status == 200
      assert text_put("/#{bucket}/ok.txt", "trustworthy bytes").status == 200

      get = call(conn(:get, "/#{bucket}/ok.txt"))
      assert get.status == 200
      assert get.resp_body == "trustworthy bytes"
    end

    test "a corrupted blob aborts the read instead of serving it", %{bucket: bucket} do
      assert call(conn(:put, "/#{bucket}")).status == 200
      assert text_put("/#{bucket}/rot.txt", "the original bytes").status == 200

      # Flip the blob on disk without touching the stored etag — pure bitrot.
      File.write!(AetherS3.Storage.BlobStore.path(bucket, "rot.txt"), "the tampered bytes")

      # The raise aborts the (already-started) chunked response — Plug wraps it, so
      # unwrap to confirm it's the integrity failure. In production Bandit sees the
      # exception mid-response and closes the connection without a terminating chunk.
      error =
        assert_raise Plug.Conn.WrapperError, fn ->
          call(conn(:get, "/#{bucket}/rot.txt"))
        end

      assert %AetherS3.Storage.IntegrityError{} = error.reason
    end
  end

  test "LIST v2: prefix, delimiter, and continuation-token pagination", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))

    for k <- ["a.txt", "docs/1.txt", "photos/cat.jpg", "photos/dog.jpg", "z.txt"],
        do: text_put("/#{bucket}/#{k}", "x")

    # delimiter groups nested keys into CommonPrefixes; top-level files stay Contents
    lvl = call(conn(:get, "/#{bucket}?list-type=2&delimiter=/"))
    assert lvl.status == 200
    assert lvl.resp_body =~ "<Key>a.txt</Key>"
    assert lvl.resp_body =~ "<Key>z.txt</Key>"
    assert lvl.resp_body =~ "<CommonPrefixes><Prefix>docs/</Prefix></CommonPrefixes>"
    assert lvl.resp_body =~ "<CommonPrefixes><Prefix>photos/</Prefix></CommonPrefixes>"
    refute lvl.resp_body =~ "<Key>photos/cat.jpg</Key>"

    # prefix narrows to a subtree
    sub = call(conn(:get, "/#{bucket}?list-type=2&prefix=photos/"))
    assert sub.resp_body =~ "<Key>photos/cat.jpg</Key>"
    assert sub.resp_body =~ "<Key>photos/dog.jpg</Key>"
    refute sub.resp_body =~ "<Key>a.txt</Key>"

    # pagination: first page truncates and hands back a token
    p1 = call(conn(:get, "/#{bucket}?list-type=2&max-keys=2"))
    assert p1.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert p1.resp_body =~ "<Key>a.txt</Key>"
    assert p1.resp_body =~ "<Key>docs/1.txt</Key>"
    token = p1.resp_body |> extract("NextContinuationToken")

    # second page resumes after the token and finishes the listing
    p2 = call(conn(:get, "/#{bucket}?list-type=2&max-keys=2&continuation-token=#{token}"))
    assert p2.resp_body =~ "<Key>photos/cat.jpg</Key>"
    refute p2.resp_body =~ "<Key>a.txt</Key>"
  end

  defp extract(xml, tag) do
    [_, value] = Regex.run(~r|<#{tag}>([^<]+)</#{tag}>|, xml)
    value
  end

  test "GET on a missing key returns 404 NoSuchKey", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))
    resp = call(conn(:get, "/#{bucket}/ghost.txt"))
    assert resp.status == 404
    assert resp.resp_body =~ "NoSuchKey"
  end

  test "PUT to a non-existent bucket returns 404 NoSuchBucket", %{bucket: bucket} do
    resp = text_put("/#{bucket}/x.txt", "data")
    assert resp.status == 404
    assert resp.resp_body =~ "NoSuchBucket"
  end

  test "listing returns a ListBucketResult with each key", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))
    text_put("/#{bucket}/a.txt", "a")
    text_put("/#{bucket}/b.txt", "bb")

    list = call(conn(:get, "/#{bucket}"))
    assert list.status == 200
    assert list.resp_body =~ "<Key>a.txt</Key>"
    assert list.resp_body =~ "<Key>b.txt</Key>"
  end

  test "deleting a non-empty bucket returns 409 BucketNotEmpty", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))
    text_put("/#{bucket}/x.txt", "x")

    resp = call(conn(:delete, "/#{bucket}"))
    assert resp.status == 409
    assert resp.resp_body =~ "BucketNotEmpty"
  end

  test "ranged GET returns 206 with the requested slice", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))
    text_put("/#{bucket}/data.bin", "0123456789")

    resp =
      conn(:get, "/#{bucket}/data.bin")
      |> put_req_header("range", "bytes=2-5")
      |> call()

    assert resp.status == 206
    assert resp.resp_body == "2345"
    assert get_resp_header(resp, "content-range") == ["bytes 2-5/10"]
  end

  test "full multipart upload assembles the parts", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))

    init =
      conn(:post, "/#{bucket}/big.bin?uploads")
      |> put_req_header("content-type", "text/plain")
      |> call()

    assert init.status == 200
    assert [_, upload_id] = Regex.run(~r{<UploadId>([^<]+)</UploadId>}, init.resp_body)

    p1 = call(conn(:put, "/#{bucket}/big.bin?partNumber=1&uploadId=#{upload_id}", "AAAA"))
    p2 = call(conn(:put, "/#{bucket}/big.bin?partNumber=2&uploadId=#{upload_id}", "BBBB"))
    assert p1.status == 200 and p2.status == 200
    [e1] = get_resp_header(p1, "etag")
    [e2] = get_resp_header(p2, "etag")

    body =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{e1}</ETag></Part>" <>
        "<Part><PartNumber>2</PartNumber><ETag>#{e2}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    comp = call(conn(:post, "/#{bucket}/big.bin?uploadId=#{upload_id}", body))
    assert comp.status == 200
    # completed object carries the S3 multipart ETag: <md5>-<part count>
    assert comp.resp_body =~ ~r|<ETag>"[0-9a-f]{32}-2"</ETag>|

    get = call(conn(:get, "/#{bucket}/big.bin"))
    assert get.resp_body == "AAAABBBB"

    # HEAD reports the total assembled size and the content-type set at Initiate
    head = call(conn(:head, "/#{bucket}/big.bin"))
    assert get_resp_header(head, "content-length") == ["8"]
    assert get_resp_header(head, "content-type") == ["text/plain"]

    # a range can span the part boundary (bytes 2-5 of "AAAABBBB" = "AABB")
    ranged =
      conn(:get, "/#{bucket}/big.bin")
      |> put_req_header("range", "bytes=2-5")
      |> call()

    assert ranged.status == 206
    assert ranged.resp_body == "AABB"
    assert get_resp_header(ranged, "content-range") == ["bytes 2-5/8"]
  end

  test "deleting a multipart object cascades to its part objects", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))

    init = call(conn(:post, "/#{bucket}/doomed.bin?uploads"))
    [_, upload_id] = Regex.run(~r{<UploadId>([^<]+)</UploadId>}, init.resp_body)

    p1 = call(conn(:put, "/#{bucket}/doomed.bin?partNumber=1&uploadId=#{upload_id}", "AAAA"))
    [e1] = get_resp_header(p1, "etag")

    body =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{e1}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    assert call(conn(:post, "/#{bucket}/doomed.bin?uploadId=#{upload_id}", body)).status == 200

    # the backing part is a real object under the reserved bucket
    part_key = Multipart.part_key(upload_id, 1)
    assert {:ok, _meta, _node} = Coordinator.locate(Multipart.bucket(), part_key)

    assert call(conn(:delete, "/#{bucket}/doomed.bin")).status == 204
    # both the object and its backing part are gone
    assert call(conn(:get, "/#{bucket}/doomed.bin")).status == 404
    assert Coordinator.locate(Multipart.bucket(), part_key) == :not_found

    assert call(conn(:get, "/__mpu__/whatever")).status == 404
  end

  test "aborting a multipart upload discards it", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))
    init = call(conn(:post, "/#{bucket}/gone.bin?uploads"))
    [_, upload_id] = Regex.run(~r{<UploadId>([^<]+)</UploadId>}, init.resp_body)

    assert call(conn(:delete, "/#{bucket}/gone.bin?uploadId=#{upload_id}")).status == 204
    # the object was never completed, so it does not exist
    resp = call(conn(:get, "/#{bucket}/gone.bin"))
    assert resp.status == 404
    assert resp.state == :sent
  end
end
