defmodule AetherS3.Replication.BlobReader do
  @moduledoc """
  Reads a byte range from a local blob. Invoked via :erpc by a coordinator node
  that is proxying a GET for an object stored on this node. Returns the bytes for
  [offset, offset+length) — `{:ok, data}` or `:eof`. Open/close per call keeps it
  stateless across the per-chunk :erpc calls.
  """
  alias AetherS3.Storage.BlobStore

  @spec read(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | :eof
  def read(bucket, key, offset, length) do
    path = BlobStore.path(bucket, key)
    {:ok, fd} = :file.open(path, [:read, :raw, :binary])

    try do
      :file.pread(fd, offset, length)
    after
      :file.close(fd)
    end
  end
end
