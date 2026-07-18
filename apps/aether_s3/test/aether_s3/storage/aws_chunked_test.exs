defmodule AetherS3.Storage.AwsChunkedTest do
  use ExUnit.Case, async: true

  alias AetherS3.Storage.AwsChunked

  # Frame `data` into aws-chunked, `size`-byte chunks. `sig?` adds a (bogus)
  # per-chunk signature extension the way signed streaming uploads do.
  defp frame(data, size, sig? \\ false) do
    ext = if sig?, do: ";chunk-signature=" <> String.duplicate("a", 64), else: ""

    body =
      data
      |> chunk_binary(size)
      |> Enum.map_join(fn part ->
        "#{Integer.to_string(byte_size(part), 16)}#{ext}\r\n#{part}\r\n"
      end)

    # Terminal 0-chunk + a trailer header (unsigned-payload-trailer style).
    body <> "0#{ext}\r\n" <> "x-amz-checksum-crc32:AAAAAA==\r\n\r\n"
  end

  # Decode by feeding the framed body in arbitrary-sized slices.
  defp decode_in_slices(framed, slice) do
    framed
    |> chunk_binary(slice)
    |> Enum.reduce({AwsChunked.new(), []}, fn seg, {st, acc} ->
      {:ok, out, st} = AwsChunked.decode(st, seg)
      {st, [out | acc]}
    end)
    |> then(fn {_st, acc} -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)
  end

  defp chunk_binary(bin, n) when byte_size(bin) <= n, do: [bin]

  defp chunk_binary(bin, n) do
    <<head::binary-size(n), rest::binary>> = bin
    [head | chunk_binary(rest, n)]
  end

  test "decodes a single-chunk unsigned body back to the original" do
    data = "hello world"
    framed = frame(data, byte_size(data))
    assert {:ok, out, _st} = AwsChunked.decode(AwsChunked.new(), framed)
    assert IO.iodata_to_binary(out) == data
  end

  test "reconstructs multi-chunk data regardless of read boundaries" do
    data = :crypto.strong_rand_bytes(10_000)
    framed = frame(data, 137)

    # Whole, and fed one byte at a time — both must reproduce the original.
    assert {:ok, whole, _} = AwsChunked.decode(AwsChunked.new(), framed)
    assert IO.iodata_to_binary(whole) == data

    byte_by_byte =
      framed
      |> :binary.bin_to_list()
      |> Enum.reduce({AwsChunked.new(), []}, fn b, {st, acc} ->
        {:ok, out, st} = AwsChunked.decode(st, <<b>>)
        {st, [out | acc]}
      end)
      |> then(fn {_st, acc} -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)

    assert byte_by_byte == data
  end

  test "strips per-chunk signatures (signed streaming)" do
    data = :crypto.strong_rand_bytes(5_000)
    framed = frame(data, 512, true)
    assert decode_in_slices(framed, 64) == data
  end

  test "handles a zero-length object" do
    framed = frame("", 8)
    assert {:ok, out, _st} = AwsChunked.decode(AwsChunked.new(), framed)
    assert IO.iodata_to_binary(out) == ""
  end

  test "encoded?/1 detects the streaming markers" do
    import Plug.Test
    import Plug.Conn

    refute AwsChunked.encoded?(conn(:put, "/b/k", "x"))

    assert conn(:put, "/b/k", "x")
           |> put_req_header("x-amz-content-sha256", "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
           |> AwsChunked.encoded?()

    assert conn(:put, "/b/k", "x")
           |> put_req_header("content-encoding", "aws-chunked")
           |> AwsChunked.encoded?()
  end
end
