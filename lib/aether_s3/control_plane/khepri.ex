defmodule AetherS3.ControlPlane.Khepri do
  @moduledoc """
  Starts the local Khepri store. Before starting, it runs an eviction GATE: if we
  have prior cluster state (marker) but a peer that is in a multi-node cluster says
  we're no longer a member, we were evicted while down — so we wipe the stale Ra
  dir BEFORE `:khepri.start`. This avoids the wedge entirely (a store booted with
  stale membership cannot be reset or stopped in-process — both hang), so recovery
  needs no external restarter; the node simply boots fresh and rejoins.
  """
  require Logger

  alias AetherS3.ControlPlane.Membership

  @gate_timeout_ms 8_000

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def start_link do
    gate_against_eviction()
    {:ok, _store} = :khepri.start(Membership.khepri_dir())
    :ignore
  end

  # Only relevant if we were a member before. Wait briefly for a clustered peer
  # (libcluster connects asynchronously, and it starts before us), then ask whether
  # we're still a member. Excluded -> wipe. No peer reachable in time -> keep our
  # data and proceed (e.g. a full-cluster restart where nobody is up yet).
  defp gate_against_eviction do
    if Membership.clustered_before?() do
      case wait_for_authoritative_members(@gate_timeout_ms) do
        {:ok, members} ->
          unless Node.self() in members do
            Logger.error(
              "Khepri: evicted while down (a peer's member list excludes us) — " <>
                "wiping stale Ra state before starting"
            )

            Membership.wipe_khepri()
          end

        :unknown ->
          :ok
      end
    end
  end

  defp wait_for_authoritative_members(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_members(deadline)
  end

  defp poll_members(deadline) do
    case Membership.authoritative_members() do
      {:ok, members} ->
        {:ok, members}

      :unknown ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          poll_members(deadline)
        else
          :unknown
        end
    end
  end
end
