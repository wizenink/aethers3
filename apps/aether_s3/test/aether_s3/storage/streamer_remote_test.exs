defmodule AetherS3.Storage.StreamerRemoteTest do
  # Exercises the remote (cross-node) egress path — including the read-ahead
  # pipeline in remote_slice — by streaming from Node.self() over :erpc, which
  # behaves exactly like a real peer but needs no second node.
  use ExUnit.Case
  import Plug.Test

  alias AetherS3.Storage.Streamer
  alias AetherS3.Storage.BlobStore

  setup do
    bucket = "streamer-remote-test"
    key = "blob-#{System.unique_integer([:positive])}"
    # > 2 chunks (@chunk is 1 MB) so we cross boundaries and use the prefetch.
    data = :crypto.strong_rand_bytes(2_500_000)

    path = BlobStore.path(bucket, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)

    %{bucket: bucket, key: key, data: data}
  end

  test "streams a multi-chunk blob from a remote node intact", ctx do
    conn =
      conn(:get, "/#{ctx.bucket}/#{ctx.key}")
      |> Streamer.egress_remote(Node.self(), ctx.bucket, ctx.key, byte_size(ctx.data))

    assert conn.status == 200
    assert IO.iodata_to_binary(conn.resp_body) == ctx.data
  end

  test "serves a byte range from a remote node", ctx do
    conn =
      conn(:get, "/#{ctx.bucket}/#{ctx.key}")
      |> Streamer.egress_remote(Node.self(), ctx.bucket, ctx.key, byte_size(ctx.data),
        range: "bytes=1000-1099"
      )

    assert conn.status == 206
    assert IO.iodata_to_binary(conn.resp_body) == binary_part(ctx.data, 1000, 100)
  end
end
