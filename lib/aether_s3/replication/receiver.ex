defmodule AetherS3.Replication.Receiver do
  alias AetherS3.Storage.BlobStore
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta

  # A blob push is staged to a per-push temp file (keyed by a unique `token`) and
  # atomically renamed into place on `finish/4`. This makes concurrent pushes to
  # the same key safe — last rename wins, no interleaved appends or rm-mid-write —
  # and crash-safe: a crash leaves an orphan temp, never a half-written blob at
  # the real path. `commit/3` (meta-only) stays for manifest objects / markers,
  # which have no blob.

  def begin(bucket, key, token) do
    File.mkdir_p!(Path.dirname(BlobStore.path(bucket, key)))
    # Create the (empty) temp up front. A ZERO-byte object streams no chunks, so
    # write_chunk/4 never fires — without this there'd be no file for finish/4 to
    # rename, and empty objects (incl. those created by unsupported CopyObject
    # requests) couldn't replicate: `:ok = File.rename` would badmatch on :enoent.
    File.write!(tmp_path(bucket, key, token), "")
    :ok
  end

  def write_chunk(bucket, key, token, chunk) do
    File.write!(tmp_path(bucket, key, token), chunk, [:append])
    :ok
  end

  # Atomically publish the staged blob, then write metadata (metadata-last). If the
  # staged temp is gone (e.g. the object was deleted mid-repair), don't crash the
  # push — the next anti-entropy cycle reconciles.
  def finish(bucket, key, token, meta) do
    case File.rename(tmp_path(bucket, key, token), BlobStore.path(bucket, key)) do
      :ok -> commit(bucket, key, meta)
      {:error, reason} -> {:error, reason}
    end
  end

  # Meta-only write — used for manifest objects and upload markers (no blob).
  def commit(bucket, key, meta) do
    ObjectMeta.put(bucket, key, meta)
  end

  def delete(bucket, key) do
    ObjectMeta.delete(bucket, key)
    File.rm(BlobStore.path(bucket, key))
    :ok
  end

  defp tmp_path(bucket, key, token), do: "#{BlobStore.path(bucket, key)}.#{token}.tmp"
end
