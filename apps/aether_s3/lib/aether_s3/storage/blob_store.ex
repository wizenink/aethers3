defmodule AetherS3.Storage.BlobStore do
  @spec path(String.t(), String.t()) :: String.t()
  def path(bucket, key) do
    storage_key = "#{bucket}/#{key}"
    hash = :crypto.hash(:sha256, storage_key) |> Base.encode16(case: :lower)
    aa = String.slice(hash, 0, 2)
    bb = String.slice(hash, 2, 2)

    Path.join([data_dir(), "blobs", bucket, aa, bb, hash])
  end

  @doc "Root of the on-disk blob tree for this node."
  def blobs_dir, do: Path.join(data_dir(), "blobs")

  @doc """
  Delete orphaned staging temp files older than `grace_ms` and return the paths
  removed. Two kinds sit alongside blobs in the tree: `<hash>.<token>.staging` (a
  crashed local PUT ingest) and `<hash>.<token>.tmp` (a crashed remote push). A
  completed write renames atomically *off* its temp path, so a temp that has
  outlived the grace can only be a crash orphan — always safe to reclaim. Local
  to this node; `dir` is overridable for tests.
  """
  def sweep_orphan_temps(grace_ms, dir \\ blobs_dir()) do
    cutoff = System.os_time(:second) - div(grace_ms, 1000)

    [Path.join(dir, "**/*.staging"), Path.join(dir, "**/*.tmp")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(fn f ->
      match?({:ok, %File.Stat{mtime: m}} when m <= cutoff, File.stat(f, time: :posix))
    end)
    |> Enum.filter(fn f -> File.rm(f) == :ok end)
  end

  defp data_dir do
    Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")
  end
end
