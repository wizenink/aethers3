defmodule AetherS3.Storage.Scrubber do
  @moduledoc """
  Background integrity scrub — detects and heals silent disk corruption (bitrot).

  Each pass re-reads every local blob and compares its md5 to the stored etag. A
  mismatch (or a blob that's missing for an object we hold) is healed by pulling
  a *verified* copy from a replica; if no replica has a good copy it's logged
  unrecoverable. This closes the gap anti-entropy leaves: anti-entropy reconciles
  metadata *versions*, so it never notices a blob whose bytes rotted while its
  metadata stayed intact on every node.

  Opt-in via `:scrub_interval_ms` (env `AETHER_SCRUB_INTERVAL`, seconds) — disabled
  when unset. Per node (each scrubs the blobs it holds), not leader-gated. Only
  regular objects and multipart parts have a blob to check; manifests (`:parts`)
  and upload markers (no `:etag`) are skipped. A short pause between blobs keeps a
  full pass from saturating disk IO.
  """
  use GenServer
  require Logger

  alias AetherS3.Cluster.RingServer
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.Replication.Coordinator
  alias AetherS3.Storage.BlobStore

  @read_chunk 1_048_576
  @throttle_ms 5

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case interval() do
      nil ->
        # Disabled — don't start the process at all.
        :ignore

      ms ->
        Logger.info("scrubber: integrity scrub every #{div(ms, 1000)}s")
        schedule(ms)
        {:ok, %{}}
    end
  end

  @impl true
  def handle_info(:scrub, state) do
    scrub_pass()
    schedule(interval())
    {:noreply, state}
  end

  @doc "Run one full scrub pass over this node's local blobs."
  def scrub_pass do
    ObjectMeta.all()
    |> Stream.filter(&has_blob?/1)
    |> Enum.each(fn {bucket, key, meta} ->
      emit(scrub_object(bucket, key, meta))
      Process.sleep(@throttle_ms)
    end)
  end

  @doc """
  Verify one object's blob against its stored etag, healing on failure. Returns
  `:ok` (intact), `:healed` (was bad, pulled a good copy), or `:unrecoverable`
  (bad/missing and no replica has a good copy).
  """
  @spec scrub_object(String.t(), String.t(), map()) :: :ok | :healed | :unrecoverable
  def scrub_object(bucket, key, %{etag: etag} = meta) do
    path = BlobStore.path(bucket, key)

    if intact?(path, etag) do
      :ok
    else
      Logger.warning("scrub: #{bucket}/#{key} failed integrity check (expected #{etag}); healing")
      heal(bucket, key, meta, etag)
    end
  end

  # --- verification --------------------------------------------------------

  defp has_blob?({_bucket, _key, meta}),
    do: Map.has_key?(meta, :etag) and not Map.has_key?(meta, :parts)

  defp intact?(path, etag), do: File.exists?(path) and blob_md5(path) == etag

  # Constant-memory md5 over the blob file.
  defp blob_md5(path) do
    {:ok, fd} = :file.open(path, [:read, :raw, :binary])

    try do
      md5_loop(fd, :crypto.hash_init(:md5))
    after
      :file.close(fd)
    end
  end

  defp md5_loop(fd, ctx) do
    case :file.read(fd, @read_chunk) do
      {:ok, data} -> md5_loop(fd, :crypto.hash_update(ctx, data))
      :eof -> ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
    end
  end

  # --- healing -------------------------------------------------------------

  # Drop the bad local blob, then ask each other replica in turn to push its copy;
  # accept the first one that actually verifies (a replica may be corrupt too).
  defp heal(bucket, key, meta, etag) do
    path = BlobStore.path(bucket, key)
    File.rm(path)

    replicas =
      "#{bucket}/#{key}" |> RingServer.replicas() |> Enum.reject(&(&1 == Node.self()))

    if Enum.any?(replicas, fn r ->
         pull_from(r, bucket, key, meta) == :ok and intact?(path, etag)
       end) do
      Logger.info("scrub: healed #{bucket}/#{key} from a replica")
      :healed
    else
      Logger.error("scrub: UNRECOVERABLE #{bucket}/#{key} — no replica holds a good copy")
      :unrecoverable
    end
  end

  # Ask `replica` to push its local blob for bucket/key to this node.
  defp pull_from(replica, bucket, key, meta) do
    case :erpc.call(replica, Coordinator, :push_blob, [Node.self(), bucket, key, meta]) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # --- plumbing ------------------------------------------------------------

  defp emit(outcome), do: :telemetry.execute([:aether, :scrub, outcome], %{count: 1}, %{})
  defp schedule(ms), do: Process.send_after(self(), :scrub, ms)
  defp interval, do: Application.get_env(:aether_s3, :scrub_interval_ms)
end
