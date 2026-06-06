defmodule AetherS3.Replication.Coordinator do
  require Logger

  alias AetherS3.Cluster.RingServer
  alias AetherS3.Storage.{BlobStore, Streamer}
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.Replication.Receiver

  @chunk 1_048_576

  def put(conn, bucket, key, content_type) do
    replicas = RingServer.replicas("#{bucket}/#{key}")
    staged = BlobStore.path(bucket, key)

    case Streamer.ingest(conn, staged) do
      {:ok, %{size: size, etag: etag}} ->
        meta = %{
          size: size,
          etag: etag,
          content_type: content_type,
          last_modified: DateTime.utc_now()
        }

        # W1: first replica synchronously, the rest fire-and-forget.
        # TODO: Implement W=[2..]
        [head | tail] = replicas
        :ok = replicate_to(head, bucket, key, staged, meta)

        Enum.each(tail, fn t ->
          Task.start(fn -> replicate_to(t, bucket, key, staged, meta) end)
        end)

        {:ok, etag}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def locate(bucket, key) do
    replicas = RingServer.replicas("#{bucket}/#{key}")

    Enum.find_value(replicas, :not_found, fn node ->
      case get_meta_from(node, bucket, key) do
        {:ok, meta} -> {:ok, meta, node}
        :not_found -> nil
      end
    end)
  end

  defp replicate_to(target, bucket, key, _staged, meta) when target == node() do
    ObjectMeta.put(bucket, key, meta)
  end

  defp replicate_to(target, bucket, key, staged, meta) do
    :ok = :erpc.call(target, Receiver, :begin, [bucket, key])

    staged
    |> File.stream!(@chunk)
    |> Enum.each(fn chunk ->
      :ok = :erpc.call(target, Receiver, :write_chunk, [bucket, key, chunk])
    end)

    :erpc.call(target, Receiver, :commit, [bucket, key, meta])
  rescue
    e ->
      Logger.warning("Replication to #{target} failed: #{inspect(e)}")
      {:error, e}
  end

  defp get_meta_from(node, bucket, key) when node == node() do
    ObjectMeta.get(bucket, key)
  end

  defp get_meta_from(node, bucket, key) do
    :erpc.call(node, AetherS3.ObjectMeta.Store, :get, [bucket, key])
  rescue
    _ -> :not_found
  end
end
