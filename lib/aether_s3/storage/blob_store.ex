defmodule AetherS3.Storage.BlobStore do
  @spec path(String.t(), String.t()) :: String.t()
  def path(bucket, key) do
    storage_key = "#{bucket}/#{key}"
    hash = :crypto.hash(:sha256, storage_key) |> Base.encode16(case: :lower)
    aa = String.slice(hash, 0, 2)
    bb = String.slice(hash, 2, 2)

    Path.join([data_dir(), "blobs", bucket, aa, bb, hash])
  end

  @spec multipart_part_path(String.t(), non_neg_integer()) :: String.t()
  def multipart_part_path(upload_id, part_number) do
    Path.join([data_dir(), "multipart", upload_id, Integer.to_string(part_number)])
  end

  defp data_dir do
    Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")
  end
end
