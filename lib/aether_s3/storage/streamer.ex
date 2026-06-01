defmodule AetherS3.Storage.Streamer do
  @chunk 1_000_000

  @spec ingest(String.t(), String.t()) ::
          {:ok, %{size: non_neg_integer(), etag: String.t()}} | {:error, term()}
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

      {:ok, chunk, _conn} ->
        :ok = :file.write(fd, chunk)

        etag =
          md5_ctx
          |> :crypto.hash_update(chunk)
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, %{size: size + byte_size(chunk), etag: etag}}

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
        |> Stream.flat_map(fn path -> File.stream!(path, [], @chunk) end)
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
