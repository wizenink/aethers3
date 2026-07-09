defmodule AetherS3.Replication.ReceiverTest do
  # Touches the shared blob store + ObjectMeta -> not async.
  use ExUnit.Case, async: false

  alias AetherS3.Replication.Receiver
  alias AetherS3.Storage.BlobStore

  defp meta do
    %{
      size: 0,
      etag: "d41d8cd98f00b204e9800998ecf8427e",
      content_type: "application/octet-stream",
      last_modified: DateTime.utc_now(),
      vv: %{}
    }
  end

  defp bucket, do: "rcv-#{System.unique_integer([:positive])}"

  test "a zero-byte object replicates: begin + finish with no chunks yields an empty blob" do
    b = bucket()
    # A 0-byte object streams no chunks, so write_chunk/4 never fires. Before the
    # fix, finish/4 crashed with a :enoent badmatch (no temp to rename).
    assert Receiver.begin(b, "empty.bin", "tok1") == :ok
    assert Receiver.finish(b, "empty.bin", "tok1", meta()) == :ok

    path = BlobStore.path(b, "empty.bin")
    assert File.exists?(path)
    assert File.read!(path) == ""

    Receiver.delete(b, "empty.bin")
  end

  test "finish with a missing staged temp returns an error instead of crashing" do
    assert {:error, :enoent} = Receiver.finish(bucket(), "gone.bin", "no-such-token", meta())
  end

  test "a normal push still stores the bytes: begin + write_chunk + finish" do
    b = bucket()
    assert Receiver.begin(b, "data.bin", "tok2") == :ok
    assert Receiver.write_chunk(b, "data.bin", "tok2", "hello ") == :ok
    assert Receiver.write_chunk(b, "data.bin", "tok2", "world") == :ok
    assert Receiver.finish(b, "data.bin", "tok2", meta()) == :ok

    assert File.read!(BlobStore.path(b, "data.bin")) == "hello world"
    Receiver.delete(b, "data.bin")
  end
end
