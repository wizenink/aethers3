defmodule AetherS3.Replication.Reaper do
  @moduledoc """
  Periodic orphan sweeper, running two independent passes each tick:

    * Abandoned multipart uploads — those whose `_init` marker has outlived
      `:mpu_reap_age_ms` without a Complete or Abort (`Coordinator.reap_incomplete_uploads/1`).
      Opt-in (unset = disabled) and leader-gated: only the Ra leader drives this
      cluster-wide sweep, so nodes don't redundantly scan and fan out the same
      deletes. The age grace keeps in-flight uploads safe.

    * Orphaned staging temp files — `.staging`/`.tmp` blobs left by a crash
      mid-write (`BlobStore.sweep_orphan_temps/1`). Local to each node (not
      leader-gated) and always-on: reclaiming a provably-orphaned internal temp
      is never destructive, unlike deleting upload parts. `:staging_sweep_age_ms`
      (default 1h) is the grace that protects a write still in flight.
  """
  use GenServer
  require Logger

  alias AetherS3.Replication.Coordinator
  alias AetherS3.Storage.BlobStore

  @interval :timer.seconds(60)
  @default_staging_sweep_ms :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reap, state) do
    # Independent passes: a persistent error in one must not starve the other.
    safely("multipart-upload reap", &reap_incomplete_uploads/0)
    safely("staging-temp sweep", &sweep_staging_temps/0)
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :reap, @interval)

  defp reap_incomplete_uploads do
    grace = Application.get_env(:aether_s3, :mpu_reap_age_ms)

    if is_integer(grace) and leader?() do
      case Coordinator.reap_incomplete_uploads(grace) do
        0 ->
          :ok

        n ->
          Logger.info("reaper: swept #{n} abandoned multipart upload(s)")
          :telemetry.execute([:aether, :reaper, :mpu], %{count: n}, %{})
      end
    end
  end

  defp sweep_staging_temps do
    grace = Application.get_env(:aether_s3, :staging_sweep_age_ms, @default_staging_sweep_ms)

    case BlobStore.sweep_orphan_temps(grace) do
      [] ->
        :ok

      files ->
        Logger.info("reaper: swept #{length(files)} orphaned staging temp file(s)")
        :telemetry.execute([:aether, :reaper, :staging], %{count: length(files)}, %{})
    end
  end

  defp safely(what, fun) do
    fun.()
  rescue
    e -> Logger.warning("reaper: #{what} error: #{inspect(e)}")
  catch
    kind, reason -> Logger.warning("reaper: #{what} crash: #{inspect({kind, reason})}")
  end

  # Only the Ra leader drives cluster-wide reaping (same source of truth the
  # eviction reconciler uses).
  defp leader? do
    case :ra_leaderboard.lookup_leader(:khepri) do
      {:khepri, leader} -> leader == Node.self()
      _ -> false
    end
  end
end
