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
    final = BlobStore.path(bucket, key)
    staged = "#{final}.#{rand_token()}.staging"

    case Streamer.ingest(conn, staged) do
      {:ok, %{size: size, etag: etag}, conn} ->
        # Atomic local publish: concurrent PUTs of the same key each ingest their
        # own temp, then rename — last writer wins, never an interleaved/corrupt
        # blob, and a crash leaves an orphan temp instead of a half-written final.
        :ok = File.rename(staged, final)

        meta = %{
          size: size,
          etag: etag,
          content_type: content_type,
          last_modified: DateTime.utc_now()
        }

        # Replicate to W replicas synchronously before acking; the rest go in the
        # background. Individual replica failures don't crash the write — they just
        # don't count toward W (and heal later via read-repair / anti-entropy).
        #
        # TODO: crash/partition orphans + failed replications still need an
        # anti-entropy reaper (sweep blobs lacking local metadata + not HRW-owned).
        # The cleaner long-term design is "route-to-primary": stream the body to the
        # HRW primary, which stages and fans out, so bytes only land on replicas.
        # W resolves against the replication factor (intended N), NOT the live
        # replica count — otherwise losing replicas would silently shrink W and
        # defeat the durability guarantee. If fewer than W live replicas exist,
        # sync_replicate can't reach W and the write is rejected.
        rf = Application.get_env(:aether_s3, :replication_factor, 3)
        w = resolve_w(rf, Application.get_env(:aether_s3, :write_quorum, 1))

        case sync_replicate(replicas, w, bucket, key, final, meta) do
          {:ok, succeeded} ->
            Logger.info(
              "stored #{bucket}/#{key} (#{size}B etag=#{etag}) W=#{w} → #{inspect(succeeded)}"
            )

            Task.start(fn ->
              Enum.each(replicas -- succeeded, fn t ->
                replicate_to(t, bucket, key, final, meta)
              end)

              unless Node.self() in replicas, do: File.rm(final)
            end)

            {:ok, etag, conn}

          {:error, :insufficient_replicas} ->
            unless Node.self() in replicas, do: File.rm(final)
            {:error, :insufficient_replicas, conn}
        end

      {:error, reason} ->
        File.rm(staged)
        {:error, reason}
    end
  end

  @doc """
  Resolve the write quorum W against the replication factor `n` (intended N, not
  the live replica count). `setting` is an integer (clamped to `[1, n]`),
  `:quorum` (⌊n/2⌋+1), or `:all` (n).
  """
  def resolve_w(n, setting) do
    case setting do
      :quorum -> div(n, 2) + 1
      :all -> n
      w when is_integer(w) -> w |> max(1) |> min(n)
    end
  end

  # Replicate in HRW order until W replicas ack, tolerating individual failures.
  # Returns {:ok, acked_nodes} if at least W succeeded, else :insufficient_replicas.
  defp sync_replicate(replicas, w, bucket, key, staged, meta) do
    succeeded =
      Enum.reduce_while(replicas, [], fn node, acc ->
        acc = if replicate_to(node, bucket, key, staged, meta) == :ok, do: [node | acc], else: acc
        if length(acc) >= w, do: {:halt, acc}, else: {:cont, acc}
      end)

    if length(succeeded) >= w, do: {:ok, succeeded}, else: {:error, :insufficient_replicas}
  end

  defp rand_token, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

  def push_blob(target, bucket, key, meta) do
    staged = BlobStore.path(bucket, key)
    # unique per-push token so the target stages to its own temp file; concurrent
    # pushes to the same key can't interleave (each renames atomically on finish).
    token = rand_token()
    :ok = :erpc.call(target, Receiver, :begin, [bucket, key, token])

    staged
    |> File.stream!(@chunk)
    |> Enum.each(fn chunk ->
      :ok = :erpc.call(target, Receiver, :write_chunk, [bucket, key, token, chunk])
    end)

    :erpc.call(target, Receiver, :finish, [bucket, key, token, meta])
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

  @doc """
  Like `locate/2`, but read-repairing: queries every replica, serves the LWW
  winner (freshest `last_modified`), and asynchronously pushes the winner's data
  to any replica that is missing it or stale. Use this on client read paths
  (GET/HEAD); internal callers keep the cheaper first-found `locate/2`.

  TODO: replica metas are queried sequentially (RF RPCs per read). Parallelize
  with `Task.async_stream` to bound read latency to the slowest single replica.
  """
  def locate_repair(bucket, key) do
    replicas = RingServer.replicas("#{bucket}/#{key}")
    results = Enum.map(replicas, fn node -> {node, get_meta_from(node, bucket, key)} end)

    case plan(replicas, results) do
      :not_found ->
        :not_found

      {winner_node, winner_meta, targets} ->
        unless targets == [] do
          Task.start(fn ->
            Enum.each(targets, fn t -> repair_one(winner_node, t, bucket, key, winner_meta) end)
          end)
        end

        {:ok, winner_meta, winner_node}
    end
  end

  @doc """
  Pure read-repair planning: given the replica order and each replica's meta
  lookup result (`[{node, {:ok, meta} | :not_found}]`), return `:not_found` if no
  replica has the object, else `{winner_node, winner_meta, repair_targets}` where
  the winner is the LWW (freshest) copy and targets are the stale/missing peers.
  """
  def plan(replicas, results) do
    present = for {n, {:ok, m}} <- results, do: {n, m}

    case present do
      [] ->
        :not_found

      _ ->
        {winner_node, winner_meta} =
          Enum.max_by(present, fn {_n, m} -> m.last_modified end, DateTime)

        targets = for n <- replicas, n != winner_node, stale?(n, results, winner_meta), do: n
        {winner_node, winner_meta, targets}
    end
  end

  defp stale?(node, results, winner_meta) do
    case List.keyfind(results, node, 0) do
      {_, {:ok, m}} -> DateTime.compare(m.last_modified, winner_meta.last_modified) == :lt
      _ -> true
    end
  end

  # Manifest winner has no blob — repair its meta only (we hold it here).
  defp repair_one(_winner, target, bucket, key, %{parts: _} = meta) do
    commit_meta(target, bucket, key, meta)
  end

  # Normal object: the winner holds the bytes, so it must do the push.
  defp repair_one(winner, target, bucket, key, meta) do
    if winner == Node.self() do
      push_blob(target, bucket, key, meta)
    else
      :erpc.call(winner, __MODULE__, :push_blob, [target, bucket, key, meta])
    end
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
