defmodule AetherS3.Storage.Streamer do
  alias AetherS3.Storage.{AwsChunked, BlobStore, Multipart}

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
    chunked? = AwsChunked.encoded?(conn)

    AetherS3.Tracing.span("storage.ingest", %{"aws.chunked": chunked?}, fn ->
      try do
        if chunked? do
          # Modern SDKs (aws-cli v2, AWS SDK v2, minio-go) frame the body as
          # aws-chunked; de-frame it so we store the object, not the framing.
          do_ingest_chunked(conn, fd, :crypto.hash_init(:md5), 0, AwsChunked.new())
        else
          do_ingest(conn, fd, :crypto.hash_init(:md5), 0)
        end
      after
        :file.close(fd)
      end
    end)
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

  # Same read loop, but each raw segment is de-framed first; only decoded object
  # bytes are written and hashed, so size/etag reflect the real object.
  defp do_ingest_chunked(conn, fd, md5_ctx, size, dec) do
    case Plug.Conn.read_body(conn, length: @chunk) do
      {:more, raw, conn} ->
        with {:ok, data, dec} <- AwsChunked.decode(dec, raw) do
          :ok = :file.write(fd, data)
          n = IO.iodata_length(data)
          do_ingest_chunked(conn, fd, :crypto.hash_update(md5_ctx, data), size + n, dec)
        end

      {:ok, raw, conn} ->
        with {:ok, data, _dec} <- AwsChunked.decode(dec, raw) do
          :ok = :file.write(fd, data)
          n = IO.iodata_length(data)

          etag =
            md5_ctx
            |> :crypto.hash_update(data)
            |> :crypto.hash_final()
            |> Base.encode16(case: :lower)

          {:ok, %{size: size + n, etag: etag}, conn}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def egress(conn, path, opts \\ []) do
    AetherS3.Tracing.span("storage.egress", %{}, fn -> do_egress(conn, path, opts) end)
  end

  defp do_egress(conn, path, opts) do
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
    AetherS3.Tracing.span("storage.egress_remote", %{"peer.node": to_string(node)}, fn ->
      do_egress_remote(conn, node, bucket, key, total, opts)
    end)
  end

  defp do_egress_remote(conn, node, bucket, key, total, opts) do
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

  # Like stream_slice, but the bytes come from a peer's BlobReader over :erpc,
  # with one chunk of read-ahead: the NEXT chunk's fetch is issued (async :erpc)
  # before the current chunk is emitted, so the cross-node round-trip overlaps
  # with sending the current chunk to the client rather than serializing behind
  # it. Only the first chunk pays a full round-trip; the rest are hidden behind
  # the client send. Constant memory (at most two chunks in flight).
  defp remote_slice(node, bucket, key, start, length) do
    fetch = fn pos, remaining ->
      to_read = min(remaining, @chunk)

      :erpc.send_request(node, AetherS3.Replication.BlobReader, :read, [bucket, key, pos, to_read])
    end

    Stream.resource(
      # Prime the pipeline with the first request (state: {pos, remaining, req}).
      fn -> if length > 0, do: {start, length, fetch.(start, length)}, else: {start, 0, nil} end,
      fn
        {_pos, _remaining, nil} = acc ->
          {:halt, acc}

        {pos, remaining, req} ->
          case :erpc.receive_response(req) do
            {:ok, data} ->
              size = byte_size(data)
              pos = pos + size
              remaining = remaining - size
              # Issue the next fetch now, so it runs while we emit `data`.
              next = if remaining > 0, do: fetch.(pos, remaining), else: nil
              {[data], {pos, remaining, next}}

            :eof ->
              {:halt, {pos, 0, nil}}
          end
      end,
      # If the consumer stops early (client disconnect), best-effort drain the
      # outstanding prefetch so its response can't linger in a keep-alive
      # connection process's mailbox. Bounded so a slow/dead peer can't block.
      fn
        {_pos, _remaining, nil} -> :ok
        {_pos, _remaining, req} -> drain(req)
      end
    )
  end

  defp drain(req) do
    _ = :erpc.receive_response(req, 100)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
