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

  def egress(conn, path) do
    conn = Plug.Conn.send_chunked(conn, 200)

    File.stream!(path, [], @chunk)
    |> Enum.reduce_while(conn, fn bytes, conn ->
      case Plug.Conn.chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end
end
