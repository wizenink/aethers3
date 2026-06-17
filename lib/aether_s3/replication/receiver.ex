defmodule AetherS3.Replication.Receiver do
  alias AetherS3.Storage.BlobStore
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta

  def begin(bucket, key) do
    path = BlobStore.path(bucket, key)
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    :ok
  end

  def write_chunk(bucket, key, chunk) do
    path = BlobStore.path(bucket, key)
    File.write!(path, chunk, [:append])
    :ok
  end

  def commit(bucket, key, meta) do
    ObjectMeta.put(bucket, key, meta)
  end

  def delete(bucket, key) do
    ObjectMeta.delete(bucket, key)
    File.rm(BlobStore.path(bucket, key))
    :ok
  end
end
