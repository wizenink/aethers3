defmodule AetherS3.Storage.Streamer do
  alias AetherS3.Storage.{BlobStore, Multipart}

  @chunk 1_000_000

  # Returns the post-read conn so the caller responds on a conn that knows the body
  # was consumed. Otherwise Bandit, on a keep-alive connection, tries to drain a body
  # it thinks is unread and eats the next pipelined request (desync -> HTTP 400),
  # which `Expect: 100-continue` clients trigger constantly under concurrency.
  @spec ingest(Plug.Conn.t(), String.t()) ::
          {:ok, %{size: non_neg_integer(), etag: String.t()}, Plug.Conn.t()} | {:error, term()}
  def ingest(conn, path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, fd} = :file.open(path, [:write, :raw, :binary])

    try do
      do_ingest(conn, fd, :crypto.hash_init(:md5), 0)
    after
      :file.close(fd)
    end
  end

  defp do_ingest(conn, fd, md5_ctx, size) do
    case Plug.Conn.read_body(conn, length: @chunk) do
      {:more, chunk, conn} ->
        :ok = :file.write(fd, chunk)
        do_ingest(conn, fd, :crypto.hash_update(md5_ctx, chunk), size + byte_size(chunk))

      {:ok, chunk, conn} ->
        :ok = :file.write(fd, chunk)

        etag =
          md5_ctx
          |> :crypto.hash_update(chunk)
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, %{size: size + byte_size(chunk), etag: etag}, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def egress(conn, path, opts \\ []) do
    total = File.stat!(path).size

    {status, start, length, conn} =
      case parse_range(Keyword.get(opts, :range), total) do
        :none ->
          {200, 0, total, conn}

        {first, last} ->
          conn =
            Plug.Conn.put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{total}")

          {206, first, last - first + 1, conn}
      end

    conn =
      conn
      |> Plug.Conn.put_resp_header("accept-ranges", "bytes")
      |> Plug.Conn.send_chunked(status)

    path
    |> stream_slice(start, length)
    |> Enum.reduce_while(conn, fn bytes, conn ->
      case Plug.Conn.chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  # Lazily stream `length` bytes starting at `start`, @chunk at a time, constant memory.
  defp stream_slice(path, start, length) do
    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(path, [:read, :raw, :binary])
        {fd, start, length}
      end,
      fn {fd, pos, remaining} ->
        if remaining <= 0 do
          {:halt, {fd, pos, remaining}}
        else
          case :file.pread(fd, pos, min(remaining, @chunk)) do
            {:ok, data} -> {[data], {fd, pos + byte_size(data), remaining - byte_size(data)}}
            :eof -> {:halt, {fd, pos, 0}}
          end
        end
      end,
      fn {fd, _pos, _remaining} -> :file.close(fd) end
    )
  end

  @doc """
  Proxy a GET for an object stored on a remote `node`: pull the requested byte
  range from the holder over :erpc, chunk-by-chunk, and relay to the client.
  `total` is the object size (we already have it from the located metadata).
  """
  def egress_remote(conn, node, bucket, key, total, opts \\ []) do
    {status, start, length, conn} =
      case parse_range(Keyword.get(opts, :range), total) do
        :none ->
          {200, 0, total, conn}

        {first, last} ->
          conn =
            Plug.Conn.put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{total}")

          {206, first, last - first + 1, conn}
      end

    conn =
      conn
      |> Plug.Conn.put_resp_header("accept-ranges", "bytes")
      |> Plug.Conn.send_chunked(status)

    node
    |> remote_slice(bucket, key, start, length)
    |> Enum.reduce_while(conn, fn bytes, conn ->
      case Plug.Conn.chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  @doc """
  Stream a manifest (multipart) object: a sequence of part blobs, each a normal
  replicated object, concatenated on the wire in order. `parts` is the manifest
  list (`%{key:, size:, ...}`); `locate` is a function that maps a part to its
  holder — `locate.(part) -> {:ok, part_meta, node} | :not_found` — so this stays
  decoupled from the Coordinator.

  Resolves every part's holder *before* sending any bytes, so a missing part is a
  clean `{:error, :missing_part}` (status can't change once chunking starts).
  """
  def egress_manifest(conn, parts, locate, opts \\ []) do
    total = parts |> Enum.map(& &1.size) |> Enum.sum()

    {status, lo, hi, conn} =
      case parse_range(Keyword.get(opts, :range), total) do
        :none ->
          {200, 0, total - 1, conn}

        {first, last} ->
          conn =
            Plug.Conn.put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{total}")

          {206, first, last, conn}
      end

    # Only the parts the range overlaps, each tagged with its in-part slice, then
    # locate just those (a small range touches one or two parts, not all of them).
    located =
      parts
      |> select_parts(lo, hi)
      |> Enum.map(fn {part, skip, take} -> {part, locate.(part), skip, take} end)

    if Enum.any?(located, fn {_part, res, _skip, _take} -> res == :not_found end) do
      {:error, :missing_part}
    else
      conn =
        conn
        |> Plug.Conn.put_resp_header("accept-ranges", "bytes")
        |> Plug.Conn.send_chunked(status)

      bucket = Multipart.bucket()

      Enum.reduce_while(located, conn, fn {part, {:ok, _meta, node}, skip, take}, conn ->
        stream =
          if node == Node.self() do
            stream_slice(BlobStore.path(bucket, part.key), skip, take)
          else
            remote_slice(node, bucket, part.key, skip, take)
          end

        pump(stream, conn)
      end)
    end
  end

  # Given the absolute byte range [lo, hi] (inclusive), pick the parts it overlaps
  # and compute each one's in-part slice. Returns [{part, skip, take}] in order.
  defp select_parts(parts, lo, hi) do
    {selected, _offset} =
      Enum.reduce(parts, {[], 0}, fn part, {acc, offset} ->
        part_start = offset
        part_end = offset + part.size - 1
        from = max(lo, part_start)
        to = min(hi, part_end)

        acc =
          if from > to do
            acc
          else
            [{part, from - part_start, to - from + 1} | acc]
          end

        {acc, offset + part.size}
      end)

    Enum.reverse(selected)
  end

  # Relay a byte stream to the client, chunk by chunk. Returns a reduce_while
  # tuple so callers can drive it over many parts and stop if the peer hangs up.
  defp pump(stream, conn) do
    Enum.reduce_while(stream, {:cont, conn}, fn bytes, {:cont, conn} ->
      case Plug.Conn.chunk(conn, bytes) do
        {:ok, conn} -> {:cont, {:cont, conn}}
        {:error, :closed} -> {:halt, {:halt, conn}}
      end
    end)
  end

  # Like stream_slice, but the bytes come from a peer's BlobReader over :erpc.
  defp remote_slice(node, bucket, key, start, length) do
    Stream.resource(
      fn -> {start, length} end,
      fn {pos, remaining} ->
        if remaining <= 0 do
          {:halt, {pos, remaining}}
        else
          to_read = min(remaining, @chunk)

          case :erpc.call(node, AetherS3.Replication.BlobReader, :read, [
                 bucket,
                 key,
                 pos,
                 to_read
               ]) do
            {:ok, data} -> {[data], {pos + byte_size(data), remaining - byte_size(data)}}
            :eof -> {:halt, {pos, 0}}
          end
        end
      end,
      fn _ -> :ok end
    )
  end

  # Parse an HTTP Range header value against the object's total size.
  defp parse_range(nil, _total), do: :none

  defp parse_range("bytes=" <> spec, total) do
    case String.split(spec, "-") do
      [start_str, ""] ->
        {String.to_integer(start_str), total - 1}

      ["", suffix_str] ->
        {max(total - String.to_integer(suffix_str), 0), total - 1}

      [start_str, end_str] ->
        {String.to_integer(start_str), min(String.to_integer(end_str), total - 1)}

      _ ->
        :none
    end
  end

  defp parse_range(_other, _total), do: :none

  @spec assemble([Path.t()], Path.t()) :: {:ok, %{size: non_neg_integer(), etag: String.t()}}
  def assemble(part_paths, dest_path) do
    File.mkdir_p!(Path.dirname(dest_path))
    {:ok, out} = :file.open(dest_path, [:write, :raw, :binary])

    try do
      {size, md5} =
        part_paths
        |> Stream.flat_map(fn path -> File.stream!(path, @chunk) end)
        |> Enum.reduce({0, :crypto.hash_init(:md5)}, fn chunk, {size, md5} ->
          :ok = :file.write(out, chunk)
          {size + byte_size(chunk), :crypto.hash_update(md5, chunk)}
        end)

      :file.datasync(out)
      etag = md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:ok, %{size: size, etag: etag}}
    after
      :file.close(out)
    end
  end
end
