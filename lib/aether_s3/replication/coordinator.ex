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

        # W=1: first replica synchronously, then return. The rest replicate in the
        # background; once done, drop our staging copy if this coordinator isn't
        # itself a replica — otherwise it leaks an orphan blob.
        #
        # TODO: This only covers the happy path. Crash/partition orphans and failed
        # replications are NOT cleaned here — they need an anti-entropy reaper 
        # that sweeps blobs lacking local metadata + not owned by this node per HRW.
        # The cleaner long-term design is "route-to-primary": stream the body to the HRW
        # primary, which stages and fans out, so bytes only ever land on replicas and no
        # staging orphan is ever created (also unifies the multipart write path).
        # TODO: make W configurable (W>=2) for stronger durability-before-ack.
        [head | tail] = replicas
        :ok = replicate_to(head, bucket, key, staged, meta)

        Task.start(fn ->
          Enum.each(tail, fn t -> replicate_to(t, bucket, key, staged, meta) end)
          unless Node.self() in replicas, do: File.rm(staged)
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

  def delete(bucket, key) do
    "#{bucket}/#{key}"
    |> RingServer.replicas()
    |> Enum.each(fn node -> delete_from(node, bucket, key) end)
  end

  def list(bucket) do
    RingServer.members()
    |> Enum.flat_map(fn node -> list_from(node, bucket) end)
    |> Enum.uniq_by(fn {key, _meta} -> key end)
    |> Enum.sort_by(fn {key, _meta} -> key end)
  end

  defp list_from(node, bucket) when node == node() do
    ObjectMeta.list(bucket)
  end

  defp list_from(node, bucket) do
    :erpc.call(node, AetherS3.ObjectMeta.Store, :list, [bucket])
  rescue
    _ -> []
  end

  defp delete_from(node, bucket, key) when node == node() do
    Receiver.delete(bucket, key)
  end

  defp delete_from(node, bucket, key) do
    :erpc.call(node, Receiver, :delete, [bucket, key])
  rescue
    _ -> :ok
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
