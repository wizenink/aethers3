defmodule AetherS3.Replication.Coordinator do
  require Logger

  alias AetherS3.Cluster.RingServer
  alias AetherS3.Storage.{BlobStore, Streamer}
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.Replication.Receiver
  alias AetherS3.Replication.VersionVector
  alias AetherS3.Replication.Conflict
  alias AetherS3.Storage.Multipart

  @chunk 1_048_576

  def put(conn, bucket, key, content_type) do
    final = BlobStore.path(bucket, key)
    staged = "#{final}.#{rand_token()}.staging"

    case Streamer.ingest(conn, staged) do
      {:ok, %{size: size, etag: etag}, conn} ->
        case publish(bucket, key, staged, final, size, etag, content_type) do
          {:ok, etag, _last_modified} -> {:ok, etag, conn}
          {:error, :insufficient_replicas} -> {:error, :insufficient_replicas, conn}
        end

      {:error, reason} ->
        File.rm(staged)
        {:error, reason}
    end
  end

  @doc """
  Server-side copy: write a fresh, self-contained object at the destination from
  the bytes of an existing source object. A regular object copies its blob; a
  completed-multipart object is deep-copied by streaming its parts — so the copy
  never shares parts with the source (a later delete of either is safe). The copy
  gets a new etag (md5 of the full bytes), last_modified, and version vector.

  `content_type` nil = keep the source's (S3 metadata-directive COPY); a value
  overrides it (REPLACE).
  """
  def copy(src_bucket, src_key, dst_bucket, dst_key, content_type) do
    case locate_repair(src_bucket, src_key) do
      :not_found ->
        {:error, :no_such_key}

      {:ok, src_meta, src_node} ->
        with {:ok, segments} <- source_segments(src_bucket, src_key, src_meta, src_node) do
          final = BlobStore.path(dst_bucket, dst_key)
          staged = "#{final}.#{rand_token()}.staging"
          content_type = content_type || src_meta.content_type

          case Streamer.ingest_source(segments, staged) do
            {:ok, %{size: size, etag: etag}} ->
              case publish(dst_bucket, dst_key, staged, final, size, etag, content_type) do
                {:ok, etag, last_modified} -> {:ok, %{etag: etag, last_modified: last_modified}}
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              File.rm(staged)
              {:error, reason}
          end
        end
    end
  end

  # The source object as an ordered list of blob segments {node, bucket, key, size}:
  # one for a regular object, one per part for a multipart manifest (each part is a
  # normal replicated object under the reserved bucket, located on its own holder).
  defp source_segments(_bucket, _key, %{parts: parts}, _node) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case locate(Multipart.bucket(), part.key) do
        {:ok, _meta, node} ->
          {:cont, {:ok, [{node, Multipart.bucket(), part.key, part.size} | acc]}}

        _ ->
          {:halt, {:error, :missing_part}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      err -> err
    end
  end

  defp source_segments(bucket, key, %{size: size}, node) do
    {:ok, [{node, bucket, key, size}]}
  end

  # Publish a staged blob as the object at bucket/key: atomic rename to final,
  # stamp meta, replicate to W replicas synchronously (rest in the background).
  # Concurrent writes of the same key each stage their own temp then rename —
  # last writer wins, never an interleaved/corrupt blob; a crash leaves an orphan
  # temp, not a half-written final. W resolves against the replication factor
  # (intended N), not the live replica count, so losing replicas can't shrink W.
  # Returns {:ok, etag, last_modified} | {:error, :insufficient_replicas}.
  defp publish(bucket, key, staged, final, size, etag, content_type) do
    replicas = RingServer.replicas("#{bucket}/#{key}")
    :ok = File.rename(staged, final)
    last_modified = DateTime.utc_now()

    meta = %{
      size: size,
      etag: etag,
      content_type: content_type,
      last_modified: last_modified,
      vv: bump_vv(bucket, key)
    }

    rf = Application.get_env(:aether_s3, :replication_factor, 3)
    w = resolve_w(rf, Application.get_env(:aether_s3, :write_quorum, 1))

    case sync_replicate(replicas, w, bucket, key, final, meta) do
      {:ok, succeeded} ->
        Logger.info(
          "stored #{bucket}/#{key} (#{size}B etag=#{etag}) W=#{w} → #{inspect(succeeded)}"
        )

        emit_put(bucket, size, "ok")

        Task.start(
          AetherS3.Tracing.bind(fn ->
            Enum.each(replicas -- succeeded, fn t ->
              replicate_to(t, bucket, key, final, meta)
            end)

            unless Node.self() in replicas, do: File.rm(final)
          end)
        )

        {:ok, etag, last_modified}

      {:error, :insufficient_replicas} ->
        unless Node.self() in replicas, do: File.rm(final)
        emit_put(bucket, 0, "insufficient_replicas")
        {:error, :insufficient_replicas}
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

  # Writes to the reserved multipart bucket are parts, not logical objects.
  defp emit_put(bucket, bytes, result) do
    kind = if bucket == Multipart.bucket(), do: "part", else: "object"

    :telemetry.execute([:aether, :object, :put], %{count: 1, bytes: bytes}, %{
      result: result,
      kind: kind
    })
  end

  def push_object(target, bucket, key, meta) do
    if File.exists?(BlobStore.path(bucket, key)) do
      push_blob(target, bucket, key, meta)
    else
      AetherS3.Tracing.rpc(
        target,
        "receiver.commit",
        %{bucket: bucket},
        {Receiver, :commit, [bucket, key, meta]}
      )
    end
  end

  def push_blob(target, bucket, key, meta) do
    AetherS3.Tracing.span(
      "replica.push_blob",
      %{"peer.node": to_string(target), bytes: meta.size},
      fn ->
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

        # Terminal commit routed through a propagated client+server span, so the
        # replica node records the persist as a child of this push.
        AetherS3.Tracing.rpc(
          target,
          "receiver.finish",
          %{bucket: bucket},
          {Receiver, :finish, [bucket, key, token, meta]}
        )
      end
    )
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
    AetherS3.Tracing.span("coordinator.locate", %{bucket: bucket}, fn ->
      replicas = RingServer.replicas("#{bucket}/#{key}")
      results = Enum.map(replicas, fn node -> {node, get_meta_from(node, bucket, key)} end)

      case plan(replicas, results) do
        :not_found ->
          :not_found

        {winner_node, winner_meta, targets} ->
          :telemetry.execute([:aether, :object, :read], %{count: 1}, %{})

          unless targets == [] do
            :telemetry.execute([:aether, :read_repair], %{count: length(targets)}, %{})

            Task.start(
              AetherS3.Tracing.bind(fn ->
                Enum.each(targets, fn t ->
                  repair_one(winner_node, t, bucket, key, winner_meta)
                end)
              end)
            )
          end

          {:ok, winner_meta, winner_node}
      end
    end)
  end

  @doc """
  Pure read-repair planning: given the replica order and each replica's meta lookup
  result (`[{node, {:ok, meta} | :not_found | :error}]`), return `:not_found` if no
  replica has the object, else `{winner_node, winner_meta, repair_targets}` where the
  winner is the causally-latest copy (version vectors; LWW tiebreak for true conflicts)
  and targets are the replicas we CONFIRMED lack it (reachable-but-absent, or holding a
  version the winner supersedes). An `:error` replica (unreachable) is never a target.
  """
  def plan(replicas, results) do
    present = for {n, {:ok, m}} <- results, do: {n, m}

    case present do
      [] ->
        :not_found

      _ ->
        {winner_node, winner_meta} =
          Enum.reduce(present, fn {_n, m} = cur, {_wn, wm} = win ->
            if Conflict.winner(m, wm) == m, do: cur, else: win
          end)

        targets =
          for n <- replicas,
              n != winner_node,
              repairable?(winner_meta, result_at(n, results)),
              do: n

        {winner_node, winner_meta, targets}
    end
  end

  defp result_at(node, results) do
    case List.keyfind(results, node, 0) do
      {_, r} -> r
      _ -> :error
    end
  end

  # A replica is a repair target only if we CONFIRMED it lacks the winner: reachable
  # but absent (:not_found), or holding a version the winner supersedes. An unreachable
  # replica (:error) is left alone — repairing on an unknown state could clobber a copy
  # that is actually newer than ours.
  defp repairable?(_winner_meta, :not_found), do: true
  defp repairable?(_winner_meta, :error), do: false
  defp repairable?(winner_meta, {:ok, m}), do: Conflict.supersedes?(winner_meta, m)

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

    # Count logical object deletes only — not the cascaded part deletes above,
    # nor reaper/abort deletes (which target the reserved bucket).
    unless bucket == Multipart.bucket() do
      :telemetry.execute([:aether, :object, :delete], %{count: 1}, %{})
    end

    :ok
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
        vv: bump_vv(bucket, key),
        parts: parts
      }

      put_manifest(bucket, key, meta)
      delete(Multipart.bucket(), Multipart.init_key(upload_id))
      :telemetry.execute([:aether, :multipart, :completed], %{count: 1}, %{})
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
    AetherS3.Tracing.rpc(
      node,
      "objmeta.get",
      %{bucket: bucket},
      {ObjectMeta, :get, [bucket, key]}
    )
  rescue
    # Unreachable / RPC failure — state UNKNOWN, distinct from a reachable :not_found.
    # Read-repair must not treat "unknown" as "absent" and push over a newer copy.
    _ -> :error
  end

  @doc """
  Abort an upload: delete every part object stored under it.

  TODO: this scatter-gathers the whole `__mpu__` bucket and filters by prefix.
  Fine for now, but a prefix-range scan in ObjectMeta.Store would avoid walking
  unrelated in-flight uploads.
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

  @doc """
  Sweep abandoned multipart uploads: any upload whose `_init` marker still exists
  and is older than `grace_ms` never completed or aborted, so delete its parts +
  marker (cluster-wide, via `abort_multipart/1`).

  The marker is the liveness signal — Complete deletes it, Abort deletes
  everything — so a lingering marker means "in progress or abandoned", and the age
  grace (measured from initiation) tells the two apart without touching an upload
  that's still running. Returns the number of uploads reaped.
  """
  def reap_incomplete_uploads(grace_ms) do
    now = DateTime.utc_now()
    # marker keys are `<upload_id>/_init` (see Multipart.init_key/1)
    suffix = "/_init"

    Multipart.bucket()
    |> list()
    |> Enum.filter(fn {key, meta} ->
      String.ends_with?(key, suffix) and
        DateTime.diff(now, meta.last_modified, :millisecond) >= grace_ms
    end)
    |> Enum.map(fn {key, _meta} ->
      upload_id = String.trim_trailing(key, suffix)
      Logger.info("reaping abandoned multipart upload #{upload_id}")
      abort_multipart(upload_id)
    end)
    |> length()
  end

  def put_upload_meta(upload_id, content_type) do
    # Write-once marker, so no prior to descend — a fresh single-event vector.
    meta = %{
      content_type: content_type,
      size: 0,
      last_modified: DateTime.utc_now(),
      vv: VersionVector.increment(VersionVector.new(), Node.self())
    }

    :telemetry.execute([:aether, :multipart, :initiated], %{count: 1}, %{})
    put_manifest(Multipart.bucket(), Multipart.init_key(upload_id), meta)
  end

  # The new version's vector: increment this (coordinator) node's counter over the
  # prior version's vector, so an overwrite causally descends what it replaced.
  # `locate` reads the freshest known prior (one extra read per write — the cost
  # of version vectors). A missing/old vv-less prior starts from an empty vector.
  defp bump_vv(bucket, key) do
    prior_vv =
      case locate(bucket, key) do
        {:ok, %{vv: vv}, _node} -> vv
        _ -> VersionVector.new()
      end

    VersionVector.increment(prior_vv, Node.self())
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
