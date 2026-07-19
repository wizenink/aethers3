defmodule AetherS3.Replication.AntiEntropy do
  @moduledoc """
  Push-based replica convergence AND rebalancing on membership change. Each cycle
  walks every locally-held object and:

    * `repair/3` — pushes it to any current HRW replica whose version our copy
      *supersedes* (version vectors; LWW tiebreak for true conflicts). This also
      MIGRATES objects to new owners after the ring changes.
    * `maybe_shed/3` — if this node is no longer an HRW replica for the object,
      deletes the LOCAL copy — but only once every current replica holds a version
      we don't supersede (causally >= ours), so the last/only copy is never dropped.
  """
  alias AetherS3.Cluster.RingServer
  alias AetherS3.Replication.Coordinator
  alias AetherS3.Replication.Conflict
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
      # Push only when we've CONFIRMED the replica's state and our version supersedes
      # what it holds (missing, older, or a concurrent loser). A transient RPC failure
      # is NOT evidence the replica is empty: treating "unreachable" as "absent" would
      # let a stale local copy clobber a newer remote one (supersedes?(_, nil) is true).
      # On :error we skip and retry next tick. If the replica is newer, ITS sweep pushes to us.
      with {:ok, remote} <- fetch(replica, bucket, key),
           true <- Conflict.supersedes?(local_meta, remote) do
        Logger.info("anti-entropy: repairing #{bucket}/#{key} → #{replica}")

        # Root span so the push_object/receiver spans this triggers form one
        # coherent background trace instead of orphaned, rootless spans.
        AetherS3.Tracing.span(
          "anti_entropy.repair",
          %{bucket: bucket, "peer.node": to_string(replica)},
          fn ->
            Coordinator.push_object(replica, bucket, key, local_meta)
          end
        )

        :telemetry.execute([:aether, :anti_entropy, :repair], %{count: 1}, %{})
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
      :telemetry.execute([:aether, :anti_entropy, :shed], %{count: 1}, %{})
    end
  end

  # Safe to shed our copy only if every current replica holds a version that we do
  # NOT supersede — i.e. each is causally >= ours (or won a concurrent tiebreak).
  # A missing replica means it isn't safely there yet, so we keep our copy.
  defp safely_replicated?(replicas, bucket, key, meta) do
    Enum.all?(replicas, fn node ->
      case fetch(node, bucket, key) do
        {:ok, nil} -> false
        {:ok, remote} -> not Conflict.supersedes?(meta, remote)
        :error -> false
      end
    end)
  end

  # A reachable replica's meta as {:ok, meta} or {:ok, nil} (confirmed absent); :error
  # if the node is unreachable / the RPC failed. Callers MUST NOT treat :error as absent:
  # "unknown" is not "empty", and conflating them lets a stale write win on heal.
  defp fetch(node, bucket, key) do
    case :erpc.call(node, ObjectMeta, :get, [bucket, key], 2_000) do
      {:ok, meta} -> {:ok, meta}
      _ -> {:ok, nil}
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
