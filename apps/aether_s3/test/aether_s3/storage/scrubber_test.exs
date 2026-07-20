defmodule AetherS3.Storage.ScrubberTest do
  # Not async: writes to the shared blob tree + metadata store.
  use ExUnit.Case, async: false

  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.Storage.{BlobStore, Scrubber}

  setup do
    n = System.unique_integer([:positive])
    {:ok, bucket: "scrub-#{n}", key: "obj-#{n}"}
  end

  # Write a blob + its metadata directly, the way a stored object looks on disk.
  defp write_object(bucket, key, content) do
    path = BlobStore.path(bucket, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    etag = content |> :erlang.md5() |> Base.encode16(case: :lower)

    meta = %{
      size: byte_size(content),
      etag: etag,
      content_type: "application/octet-stream",
      last_modified: DateTime.utc_now(),
      vv: %{}
    }

    ObjectMeta.put(bucket, key, meta)
    {path, meta}
  end

  test "an intact blob passes as :ok", %{bucket: bucket, key: key} do
    {_path, meta} = write_object(bucket, key, "the bytes are exactly what the etag says")
    assert Scrubber.scrub_object(bucket, key, meta) == :ok
  end

  test "a corrupted blob is detected and (no replica) unrecoverable; bad copy dropped",
       %{bucket: bucket, key: key} do
    {path, meta} = write_object(bucket, key, "original content")
    # Flip the bytes on disk without touching the metadata — pure bitrot.
    File.write!(path, "tampered content")

    assert Scrubber.scrub_object(bucket, key, meta) == :unrecoverable
    # Heal removes the bad copy (single node here has no replica to pull from).
    refute File.exists?(path)
  end

  test "a missing blob for a held object is unrecoverable with no replica",
       %{bucket: bucket, key: key} do
    {path, meta} = write_object(bucket, key, "content")
    File.rm!(path)
    assert Scrubber.scrub_object(bucket, key, meta) == :unrecoverable
  end
end
