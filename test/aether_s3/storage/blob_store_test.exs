defmodule AetherS3.Storage.BlobStoreTest do
  use ExUnit.Case, async: true

  alias AetherS3.Storage.BlobStore

  test "path is deterministic for the same bucket/key" do
    assert BlobStore.path("b", "k") == BlobStore.path("b", "k")
  end

  test "different keys produce different paths" do
    refute BlobStore.path("b", "k1") == BlobStore.path("b", "k2")
  end

  test "path uses a two-level hex fan-out under blobs/<bucket>" do
    path = BlobStore.path("photos", "2024/cat.jpg")
    assert path =~ ~r"/blobs/photos/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}$"
  end
end
