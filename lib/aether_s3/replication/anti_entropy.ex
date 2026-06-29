defmodule AetherS3.Replication.AntiEntropy do
  @moduledoc """
  Push-based replica convergence AND rebalancing on membership change. Each cycle
  walks every locally-held object and:

    * `repair/3` — pushes it (LWW) to any current HRW replica that is missing or
      stale. This also MIGRATES objects to new owners after the ring changes.
    * `maybe_shed/3` — if this node is no longer an HRW replica for the object,
      deletes the LOCAL copy — but only once every current replica holds it at a
      version >= ours, so the last/only copy is never dropped.

  NOTE: `repair` uses `push_blob`, which assumes a blob exists, so meta-only
  objects (completed-multipart manifests and `__mpu__` markers) are not yet
  migrated to new owners on a ring change. Shedding stays safe for them
  (`safely_replicated?` fails → they are never dropped); full rebalancing of
  meta-only objects is a TODO.
  """
  alias AetherS3.Cluster.RingServer
  alias AetherS3.Replication.Coordinator
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.Replication.Receiver

  use GenServer
  require Logger

  @interval :timer.seconds(15)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :reconcile, @interval)

  def repair(bucket, key, local_meta) do
    "#{bucket}/#{key}"
    |> RingServer.replicas()
    |> Enum.reject(&(&1 == Node.self()))
    |> Enum.each(fn replica ->
      if stale?(replica, bucket, key, local_meta) do
        Logger.info("anti-entropy: repairing #{bucket}/#{key} → #{replica}")
        Coordinator.push_blob(replica, bucket, key, local_meta)
      end
    end)
  end

  def reconcile do
    Enum.each(ObjectMeta.all(), fn {bucket, key, meta} ->
      repair(bucket, key, meta)
      maybe_shed(bucket, key, meta)
    end)
  end

  defp maybe_shed(bucket, key, meta) do
    replicas = RingServer.replicas("#{bucket}/#{key}")

    if Node.self() not in replicas and safely_replicated?(replicas, bucket, key, meta) do
      Logger.info("rebalance: shedding #{bucket}/#{key} (no longer a replica for it)")
      Receiver.delete(bucket, key)
    end
  end

  defp safely_replicated?(replicas, bucket, key, meta) do
    Enum.all?(replicas, fn node ->
      case get_meta_from(node, bucket, key) do
        {:ok, remote} -> DateTime.compare(remote.last_modified, meta.last_modified) != :lt
        _ -> false
      end
    end)
  end

  defp stale?(replica, bucket, key, local_meta) do
    case get_meta_from(replica, bucket, key) do
      {:ok, remote} -> DateTime.compare(remote.last_modified, local_meta.last_modified) == :lt
      _ -> true
    end
  end

  defp get_meta_from(node, bucket, key) do
    :erpc.call(node, ObjectMeta, :get, [bucket, key], 2_000)
  rescue
    _ -> :not_found
  catch
    _, _ -> :not_found
  end
end
