defmodule AetherS3.Cluster.Status do
  @moduledoc """
  Best-effort, human-facing cluster snapshot. Fans out to every reachable node,
  gathers each node's LOCAL view, and returns a consolidated map (rendered as JSON
  by `AetherS3.AdminRouter` at `/cluster`).

  Read-only and point-in-time. During a partition it reflects the querying node's
  side and marks unreachable peers — which is exactly what you want to see. It is
  deliberately NOT a Prometheus metric: cluster-wide *metrics* belong in the query
  layer (scrape every node, aggregate in PromQL); this is the at-a-glance
  `curl`-friendly complement for when you don't have Grafana in front of you.
  """
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta

  @timeout 2_000

  @doc "Consolidated snapshot: the querying node's leader view + each node's local view."
  def snapshot do
    nodes = [Node.self() | Node.list()]

    views =
      nodes
      |> Task.async_stream(&view_of/1, timeout: @timeout + 500, on_timeout: :kill_task)
      |> Enum.zip(nodes)
      |> Map.new(fn
        {{:ok, view}, node} -> {node, view}
        {{:exit, _reason}, node} -> {node, %{error: "unreachable"}}
      end)

    %{leader: leader(), node_count: map_size(views), nodes: views}
  end

  # Own view locally; peers over erpc, capturing failures so one down node doesn't
  # sink the whole snapshot.
  defp view_of(node) when node == node(), do: local_view()

  defp view_of(node) do
    :erpc.call(node, __MODULE__, :local_view, [], @timeout)
  rescue
    e -> %{error: inspect(e)}
  catch
    _kind, reason -> %{error: inspect(reason)}
  end

  @doc false
  # Runs on each node (locally or via erpc): that node's own picture.
  def local_view do
    %{
      members: length(Node.list()) + 1,
      knows_leader: leader() != nil,
      objects: ObjectMeta.count()
    }
  end

  # Non-blocking ETS lookup (never :khepri_cluster.nodes/0, which can wedge).
  defp leader do
    case :ra_leaderboard.lookup_leader(:khepri) do
      {:khepri, leader} -> leader
      _ -> nil
    end
  end
end
