defmodule AetherS3.ControlPlane.Membership do
  @moduledoc """
  Shared Khepri/Ra membership helpers used by both the boot-time gate
  (`AetherS3.ControlPlane.Khepri`) and the runtime reconciler
  (`AetherS3.ControlPlane.Cluster`).

  The membership checks here are deliberately PEER-BASED (`:erpc` only, never the
  local Khepri API) so they never block even when the local Ra store is wedged —
  which is exactly the state an evicted node boots into.
  """

  def data_dir, do: Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")
  def khepri_dir, do: Path.join(data_dir(), "khepri")
  def marker_path, do: Path.join(data_dir(), ".cp_clustered")

  @doc "Breadcrumb written once we're confirmed in a multi-node cluster."
  def mark_clustered do
    unless File.exists?(marker_path()), do: File.write(marker_path(), "")
  end

  @doc "Were we ever a confirmed member? (distinguishes eviction from never-joined)"
  def clustered_before?, do: File.exists?(marker_path())

  @doc """
  Wipe ONLY the Khepri (Ra) state — blobs and object metadata live in separate
  dirs and are untouched; the control-plane tree resyncs from the leader on rejoin.
  """
  def wipe_khepri do
    File.rm_rf(khepri_dir())
    File.rm(marker_path())
  end

  @doc """
  Authoritative membership = the node list reported by a peer that is itself in a
  multi-node cluster. `{:ok, nodes}` or `:unknown` if no clustered peer is
  reachable (so an isolated/minority node never wrongly concludes it was evicted).
  """
  def authoritative_members do
    case Enum.find(Node.list(), &clustered?/1) do
      nil ->
        :unknown

      peer ->
        case safe_remote_nodes(peer) do
          {:ok, nodes} -> {:ok, nodes}
          _ -> :unknown
        end
    end
  end

  @doc "Is `node` part of a multi-node Ra cluster? (asked over :erpc, with timeout)"
  def clustered?(node) do
    case safe_remote_nodes(node) do
      {:ok, nodes} -> length(nodes) > 1
      _ -> false
    end
  end

  def safe_remote_nodes(node) do
    :erpc.call(node, :khepri_cluster, :nodes, [], 2_000)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
