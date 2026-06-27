defmodule AetherS3.Replication.Coordinator do
  require Logger

  alias AetherS3.Cluster.RingServer
  alias AetherS3.Storage.{BlobStore, Streamer}
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.Replication.Receiver
  alias AetherS3.Storage.Multipart

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
        Logger.info("stored #{bucket}/#{key} (#{size}B etag=#{etag}) → #{inspect(replicas)}")

        Task.start(fn ->
          Enum.each(tail, fn t -> replicate_to(t, bucket, key, staged, meta) end)
          unless Node.self() in replicas, do: File.rm(staged)
        end)

        {:ok, etag}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def push_blob(target, bucket, key, meta) do
    staged = BlobStore.path(bucket, key)
    :ok = :erpc.call(target, Receiver, :begin, [bucket, key])

    staged
    |> File.stream!(@chunk)
    |> Enum.each(fn chunk ->
      :ok = :erpc.call(target, Receiver, :write_chunk, [bucket, key, chunk])
    end)

    :erpc.call(target, Receiver, :commit, [bucket, key, meta])
  rescue
    e ->
      Logger.warning("push_blob to #{target} failed: #{inspect(e)}")
      {:error, e}
  catch
    kind, reason ->
      Logger.warning("push_blob to #{target} exited: #{inspect({kind, reason})}")
      {:error, reason}
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
    parts = manifest_parts(bucket, key)

    "#{bucket}/#{key}"
    |> RingServer.replicas()
    |> Enum.each(fn node -> delete_from(node, bucket, key) end)

    Enum.each(parts, fn p -> delete(Multipart.bucket(), p.key) end)
  end

  defp manifest_parts(bucket, key) do
    case locate(bucket, key) do
      {:ok, %{parts: parts}, _node} -> parts
      _ -> []
    end
  end

  def list(bucket) do
    RingServer.members()
    |> Enum.flat_map(fn node -> list_from(node, bucket) end)
    |> Enum.uniq_by(fn {key, _meta} -> key end)
    |> Enum.sort_by(fn {key, _meta} -> key end)
  end

  def complete_multipart(bucket, key, upload_id, requested) do
    with {:ok, parts, total} <- build_manifest(upload_id, requested) do
      etag = Multipart.multipart_etag(Enum.map(parts, & &1.etag))

      content_type =
        case get_upload_meta(upload_id) do
          {:ok, %{content_type: ct}} -> ct
          _ -> "application/octet-stream"
        end

      meta = %{
        size: total,
        etag: etag,
        content_type: content_type,
        last_modified: DateTime.utc_now(),
        parts: parts
      }

      put_manifest(bucket, key, meta)
      delete(Multipart.bucket(), Multipart.init_key(upload_id))
      {:ok, etag}
    end
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

  defp replicate_to(target, bucket, key, _staged, meta), do: push_blob(target, bucket, key, meta)

  defp get_meta_from(node, bucket, key) when node == node() do
    ObjectMeta.get(bucket, key)
  end

  defp get_meta_from(node, bucket, key) do
    :erpc.call(node, AetherS3.ObjectMeta.Store, :get, [bucket, key])
  rescue
    _ -> :not_found
  end

  @doc """
  Abort an upload: delete every part object stored under it.

  TODO: this scatter-gathers the whole `__mpu__` bucket and filters by prefix.
  Fine for now, but a prefix-range scan in ObjectMeta.Store would avoid walking
  unrelated in-flight uploads. Also leaves no trace of partially-deleted aborts —
  the future incomplete-MPU reaper should sweep orphans.
  """
  def abort_multipart(upload_id) do
    prefix = "#{upload_id}/"
    bucket = Multipart.bucket()

    bucket
    |> list()
    |> Enum.each(fn {key, _meta} ->
      if String.starts_with?(key, prefix), do: delete(bucket, key)
    end)
  end

  def put_upload_meta(upload_id, content_type) do
    meta = %{content_type: content_type, size: 0, last_modified: DateTime.utc_now()}
    put_manifest(Multipart.bucket(), Multipart.init_key(upload_id), meta)
  end

  def get_upload_meta(upload_id) do
    case locate(Multipart.bucket(), Multipart.init_key(upload_id)) do
      {:ok, meta, _node} -> {:ok, meta}
      :not_found -> :not_found
    end
  end

  defp build_manifest(upload_id, requested) do
    requested
    |> Enum.reduce_while({:ok, [], 0}, fn {pn, etag}, {:ok, acc, total} ->
      key = Multipart.part_key(upload_id, pn)

      case locate(Multipart.bucket(), key) do
        {:ok, %{etag: ^etag, size: size}, _node} ->
          part = %{number: pn, key: key, size: size, etag: etag}
          {:cont, {:ok, [part | acc], total + size}}

        _ ->
          {:halt, {:error, :invalid_part}}
      end
    end)
    |> case do
      {:ok, parts, total} -> {:ok, Enum.reverse(parts), total}
      err -> err
    end
  end

  defp put_manifest(bucket, key, meta) do
    "#{bucket}/#{key}"
    |> RingServer.replicas()
    |> Enum.each(fn node -> commit_meta(node, bucket, key, meta) end)
  end

  defp commit_meta(node, bucket, key, meta) when node == node() do
    ObjectMeta.put(bucket, key, meta)
  end

  defp commit_meta(node, bucket, key, meta) do
    :erpc.call(node, Receiver, :commit, [bucket, key, meta])
  end
end
