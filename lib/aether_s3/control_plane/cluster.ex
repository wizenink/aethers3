defmodule AetherS3.ControlPlane.Cluster do
  @moduledoc """
  Automatically joins this node to the Khepri (Ra) cluster as the BEAM cluster
  forms (libcluster connects nodes; we react to membership and poll while alone).

  Formation rule (asked in order, while we're still a singleton):

    1. If any connected peer is already in a multi-node Ra cluster, JOIN IT —
       regardless of our own name. (A late, smaller-named node joins the existing
       cluster instead of isolating itself.)
    2. Otherwise everyone is a singleton, so we're BOOTSTRAPPING: the smallest
       node name is the "former" and stays put; the rest join it. Smallest-name
       is only a tiebreaker to stop N singletons from all joining each other.

  We retry (poll) while singleton so transient failures (peer not ready, a
  concurrent Ra membership change) self-heal. Once in a multi-node cluster we stop.

  Network partitions of the control plane are handled by Raft itself: the minority
  loses write quorum (no divergence) and resyncs from the leader on heal, since
  membership persists in the Ra log. Our :nodeup handler also re-attempts a join
  on reconnect.

  TODO (CP member lifecycle):
    * Wiped-state restart: a member that restarts with an empty data dir is still
      listed as a member elsewhere but has no Ra state → Ra identity conflict.
      Needs detect-empty -> :khepri_cluster.reset -> rejoin (or evict + re-add).
    * Dead-member eviction: a permanently-down member still counts toward quorum;
      needs operator/automated removal (:khepri_cluster member removal) to restore
      the quorum margin.
  These are membership-lifecycle ops, distinct from data-plane divergence (which
  is handled by LWW + anti-entropy in AetherS3.Replication).
  """
  use GenServer
  require Logger

  @retry_ms 2_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  # A new peer appeared: try once immediately (the poll loop handles retries).
  def handle_info({:nodeup, _node}, state) do
    maybe_join()
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # The single self-rescheduling loop: attempt, and keep polling *only* while
  # we're still a singleton (so exactly one timer chain, no pileup).
  defp tick(state) do
    maybe_join()
    if singleton?(), do: Process.send_after(self(), :tick, @retry_ms)
    state
  end

  defp maybe_join do
    if singleton?() do
      peers = Node.list()

      cond do
        # 1. Join an existing multi-node cluster if one exists among our peers.
        existing = Enum.find(peers, &clustered?/1) ->
          join(existing)

        # 2. Bootstrap: all singletons -> smallest name is former, others join it.
        peers != [] and Node.self() != Enum.min([Node.self() | peers]) ->
          join(Enum.min([Node.self() | peers]))

        true ->
          :ok
      end
    end
  rescue
    e -> Logger.warning("Khepri auto-join error: #{inspect(e)}")
  end

  defp join(anchor) do
    Logger.info("Khepri: joining Ra cluster via #{anchor}")

    case :khepri_cluster.join(anchor) do
      :ok -> :ok
      other -> Logger.warning("Khepri join via #{anchor} failed: #{inspect(other)}")
    end
  end

  # Is THIS node still a one-member Ra cluster?
  defp singleton? do
    case :khepri_cluster.nodes() do
      {:ok, nodes} -> length(nodes) <= 1
      _ -> true
    end
  end

  # Is the remote `node` part of a multi-node Ra cluster? (asked over :erpc)
  defp clustered?(node) do
    case safe_remote_nodes(node) do
      {:ok, nodes} -> length(nodes) > 1
      _ -> false
    end
  end

  defp safe_remote_nodes(node) do
    :erpc.call(node, :khepri_cluster, :nodes, [], 2_000)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
