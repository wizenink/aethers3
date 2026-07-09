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

  describe "sweep_orphan_temps/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "blobstore_sweep_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "bkt/aa/bb"))
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    # create a file under the blob tree with its mtime `age_s` seconds in the past
    defp put(dir, name, age_s) do
      path = Path.join([dir, "bkt/aa/bb", name])
      File.write!(path, "x")
      File.touch!(path, System.os_time(:second) - age_s)
      path
    end

    test "removes .staging/.tmp temps older than the grace, keeps fresh ones", %{dir: dir} do
      old_staging = put(dir, "hash.tok.staging", 7200)
      old_tmp = put(dir, "hash.tok2.tmp", 7200)
      fresh_tmp = put(dir, "hash.tok3.tmp", 10)

      removed = BlobStore.sweep_orphan_temps(:timer.hours(1), dir)

      assert Enum.sort(removed) == Enum.sort([old_staging, old_tmp])
      refute File.exists?(old_staging)
      refute File.exists?(old_tmp)
      assert File.exists?(fresh_tmp)
    end

    test "never touches real blobs (no temp suffix), even old ones", %{dir: dir} do
      blob = put(dir, String.duplicate("a", 64), 7200)

      assert BlobStore.sweep_orphan_temps(0, dir) == []
      assert File.exists?(blob)
    end

    test "returns [] when there is nothing to sweep", %{dir: dir} do
      assert BlobStore.sweep_orphan_temps(0, dir) == []
    end
  end
end
