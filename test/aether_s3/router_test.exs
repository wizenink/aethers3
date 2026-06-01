defmodule AetherS3.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

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

    init = call(conn(:post, "/#{bucket}/big.bin?uploads"))
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

    get = call(conn(:get, "/#{bucket}/big.bin"))
    assert get.resp_body == "AAAABBBB"
  end

  test "aborting a multipart upload discards it", %{bucket: bucket} do
    call(conn(:put, "/#{bucket}"))
    init = call(conn(:post, "/#{bucket}/gone.bin?uploads"))
    [_, upload_id] = Regex.run(~r{<UploadId>([^<]+)</UploadId>}, init.resp_body)

    assert call(conn(:delete, "/#{bucket}/gone.bin?uploadId=#{upload_id}")).status == 204
    # the object was never completed, so it does not exist
    assert call(conn(:get, "/#{bucket}/gone.bin")).status == 404
  end
end
