defmodule AetherS3.ControlPlane.Cluster do
  @moduledoc """
  Keeps this node's membership in the Khepri (Ra) cluster healthy. A single
  reconcile loop runs three jobs:

    1. JOIN / formation — while we're a singleton, join an existing multi-node
       cluster among our peers, or (if everyone is a singleton) bootstrap by having
       the smallest-named node be the former and the rest join it. The :nodeup
       handler also fires a join immediately on reconnect.

    2. SELF-CORRECT (member lifecycle #3) — if an authoritative peer's member list
       no longer includes us, we were evicted. The primary recovery is the boot-time
       gate in `AetherS3.ControlPlane.Khepri` (wipe-before-start), which handles the
       common case (evicted while down, then restart). This runtime path covers the
       rarer case of a still-running node that was evicted during a partition: try
       an in-process stop+wipe+restart, falling back to halt (for a supervisor to
       restart) only if the local store is too wedged to stop. We act only on a
       peer's *authoritative* view — an isolated/minority node never wipes itself.

    3. REAP dead members (member lifecycle #2) — OPT-IN (set `:cp_evict_grace_ms`).
       Only the Ra leader evicts, at most one member per cycle, and only after a
       member's node has been unreachable longer than the grace period.

  Split-brain safety for #2 is inherited from Raft, not bolted on: removing a member
  is a quorum-committed log entry, and only the majority partition can elect a
  leader / commit. The minority has no committing leader, so it cannot evict anyone
  — there can never be two sides evicting each other. We add leader-gating,
  one-removal-per-cycle (Raft's single-config-change rule), a generous grace, and #3
  as the recovery net for a mistakenly-evicted but still-alive node.

  Steady-state data-plane divergence is separate (LWW + read-repair + anti-entropy
  in AetherS3.Replication); this module only manages Ra cluster membership.
  """
  use GenServer
  require Logger

  alias AetherS3.ControlPlane.Membership

  @store :khepri
  @interval 3_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{down_since: %{}}, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, reconcile(state)}

  # A new peer appeared: try a join immediately (the loop handles the rest).
  def handle_info({:nodeup, _node}, state) do
    maybe_join()
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # One self-rescheduling reconcile loop (a single timer chain, no pileup).
  # self_correct runs FIRST: it is peer-based and never calls the local Khepri API,
  # so a node whose local Ra store has wedged can still recover here before
  # maybe_join/reap touch the (blocking) local store.
  defp reconcile(state) do
    self_correct()
    maybe_join()
    state = maybe_reap(state)
    Process.send_after(self(), :tick, @interval)
    state
  end

  # --- 1. join / formation ---------------------------------------------------

  defp maybe_join do
    if singleton?() do
      peers = Node.list()

      cond do
        # Join an existing multi-node cluster if one exists among our peers.
        existing = Enum.find(peers, &Membership.clustered?/1) ->
          join(existing)

        # Bootstrap: all singletons -> smallest name is former, others join it.
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

  # --- 2. self-correct after eviction (runtime path; boot gate is primary) ----

  defp self_correct do
    case Membership.authoritative_members() do
      {:ok, members} ->
        if Node.self() in members do
          Membership.mark_clustered()
        else
          if Membership.clustered_before?() do
            Logger.error(
              "Khepri: evicted from the cluster (a peer's member list excludes us) — " <>
                "recovering (stop store, wipe Ra state, restart, rejoin)"
            )

            recover_evicted()
          end
        end

      :unknown ->
        :ok
    end
  rescue
    e -> Logger.warning("Khepri self-correct error: #{inspect(e)}")
  end

  # In-process recovery for a still-running evicted node. `khepri:stop/0` is a LOCAL
  # store stop (not a cluster leave like `reset`), so for a live-but-removed server
  # it works; if the store is too wedged to stop within the timeout, fall back to
  # halt for a supervisor to restart (and the boot gate then wipes on restart).
  defp recover_evicted do
    case stop_store(5_000) do
      :ok ->
        Membership.wipe_khepri()

        case :khepri.start(Membership.khepri_dir()) do
          {:ok, _store} ->
            Logger.info("Khepri: recovered in place after eviction — rejoining")
            maybe_join()

          err ->
            Logger.error("Khepri: restart after wipe failed: #{inspect(err)} — halting")
            System.halt(1)
        end

      :timeout ->
        Logger.error("Khepri: store stop timed out — wiping and halting for supervisor restart")
        Membership.wipe_khepri()
        System.halt(1)
    end
  end

  defp stop_store(timeout_ms) do
    task = Task.async(fn -> :khepri.stop() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, _} -> :ok
      _ -> :timeout
    end
  end

  # --- 3. reap dead members (opt-in, leader-only, one per cycle) --------------

  defp maybe_reap(state) do
    grace = Application.get_env(:aether_s3, :cp_evict_grace_ms)

    if is_integer(grace) and leader?() do
      reap(state, grace)
    else
      state
    end
  rescue
    e ->
      Logger.warning("Khepri reap error: #{inspect(e)}")
      state
  end

  defp reap(state, grace) do
    now = System.monotonic_time(:millisecond)
    live = [Node.self() | Node.list()]
    down = member_nodes() -- live

    # Track first-seen-down per node; forget any that have come back.
    down_since =
      Enum.reduce(down, Map.take(state.down_since, down), fn n, acc ->
        Map.put_new(acc, n, now)
      end)

    # Evict at most ONE: the node that has been down the longest past the grace.
    victim =
      down
      |> Enum.filter(fn n -> now - Map.fetch!(down_since, n) >= grace end)
      |> Enum.min_by(fn n -> Map.fetch!(down_since, n) end, fn -> nil end)

    case victim do
      nil ->
        %{state | down_since: down_since}

      node ->
        Logger.warning("Khepri: evicting dead member #{node} (unreachable > #{grace}ms)")

        case :ra.remove_member({@store, Node.self()}, {@store, node}) do
          {:ok, _, _} -> Logger.info("Khepri: evicted #{node}")
          other -> Logger.warning("Khepri: evict #{node} failed: #{inspect(other)}")
        end

        %{state | down_since: Map.delete(down_since, node)}
    end
  end

  defp leader? do
    case :ra_leaderboard.lookup_leader(@store) do
      {@store, leader} -> leader == Node.self()
      _ -> false
    end
  end

  defp member_nodes do
    case :khepri_cluster.nodes() do
      {:ok, nodes} -> nodes
      _ -> []
    end
  end

  # Is THIS node still a one-member Ra cluster? (local Khepri call)
  defp singleton? do
    case :khepri_cluster.nodes() do
      {:ok, nodes} -> length(nodes) <= 1
      _ -> true
    end
  end
end
