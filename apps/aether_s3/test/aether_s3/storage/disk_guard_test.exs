defmodule AetherS3.Storage.DiskGuardTest do
  # Not async: toggles the shared persistent_term flag + global app env.
  use ExUnit.Case, async: false

  alias AetherS3.Storage.DiskGuard

  @flag {DiskGuard, :writable}

  setup do
    on_exit(fn -> :persistent_term.put(@flag, true) end)
    :ok
  end

  test "writable? defaults to true when the guard hasn't reported (disabled)" do
    :persistent_term.put(@flag, true)
    assert DiskGuard.writable?()
  end

  test "a reserve larger than the disk flips writable? to false" do
    # Reserve bigger than any real filesystem -> free space is always below it.
    Application.put_env(:aether_s3, :min_free_bytes, 1_000_000_000_000_000)
    on_exit(fn -> Application.delete_env(:aether_s3, :min_free_bytes) end)

    # init runs the first poll synchronously, so the flag is set once start returns.
    {:ok, pid} = DiskGuard.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute DiskGuard.writable?()
  end

  test "a tiny reserve keeps writable? true (df measured real free space)" do
    Application.put_env(:aether_s3, :min_free_bytes, 1)
    on_exit(fn -> Application.delete_env(:aether_s3, :min_free_bytes) end)

    {:ok, pid} = DiskGuard.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert DiskGuard.writable?()
  end
end
