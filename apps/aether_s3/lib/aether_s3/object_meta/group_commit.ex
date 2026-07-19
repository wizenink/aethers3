defmodule AetherS3.ObjectMeta.GroupCommit do
  @moduledoc """
  Durable group-commit for the object-metadata store.

  With CubDB opened `auto_file_sync: false`, a `put` writes to the file but does
  not fsync — fast, but not durable on its own. `sync/0` blocks the caller until
  a single fsync has flushed its write to disk; many concurrent callers share one
  fsync.

  This keeps the **exact durability of per-write fsync** — a `put` returns only
  once its write is on disk, so there is no acked-then-lost window — while
  amortizing the fsync (the write-path bottleneck) across every write in the
  batch. A crash before the fsync loses only writes whose `put` has not yet
  returned, i.e. nothing the client was told succeeded.

  The first waiter arms a short **linger** (`@linger_ms`); every write that
  arrives during it joins the batch, and one fsync commits them all. The linger
  is what forces batching even when the disk is fast enough to fsync a lone write
  immediately (which would otherwise degrade to per-write fsync). Under heavier
  load, writes that arrive while an fsync is running queue and form the next
  batch, so the fsync rate stays bounded while batches grow.
  """
  use GenServer

  @db AetherS3.ObjectMeta.DB
  @linger_ms 5
  @sync_timeout 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Block until an fsync has made the caller's preceding CubDB write durable.

  Returns `:ok` immediately when group-commit isn't running (`:each` mode, where
  CubDB fsyncs on every write itself), so callers can invoke it unconditionally.
  """
  @spec sync() :: :ok
  def sync do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :sync, @sync_timeout)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{waiters: []}}

  @impl true
  # First waiter of a batch arms the linger; the fsync fires when it elapses.
  def handle_call(:sync, from, %{waiters: []}) do
    Process.send_after(self(), :flush, @linger_ms)
    {:noreply, %{waiters: [from]}}
  end

  def handle_call(:sync, from, %{waiters: waiters}) do
    {:noreply, %{waiters: [from | waiters]}}
  end

  @impl true
  # One fsync commits the whole batch. Running it in the GenServer serializes
  # fsyncs and makes writes that land mid-fsync queue into the next batch.
  def handle_info(:flush, %{waiters: waiters}) do
    CubDB.file_sync(@db)
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    {:noreply, %{waiters: []}}
  end
end
