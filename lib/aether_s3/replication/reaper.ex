defmodule AetherS3.Replication.Reaper do
  @moduledoc """
  Periodic orphan sweeper. Currently reaps abandoned multipart uploads — those
  whose `_init` marker has outlived `:mpu_reap_age_ms` without a Complete or Abort
  (see `Coordinator.reap_incomplete_uploads/1`).

  Opt-in (no reap age configured = disabled) and leader-gated: only the Ra leader
  drives the cluster-wide sweep, so nodes don't redundantly scan and fan out the
  same deletes. The age grace is what keeps in-flight uploads safe.
  """
  use GenServer
  require Logger

  alias AetherS3.Replication.Coordinator

  @interval :timer.seconds(60)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reap, state) do
    reap()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :reap, @interval)

  defp reap do
    grace = Application.get_env(:aether_s3, :mpu_reap_age_ms)

    if is_integer(grace) and leader?() do
      case Coordinator.reap_incomplete_uploads(grace) do
        0 -> :ok
        n -> Logger.info("reaper: swept #{n} abandoned multipart upload(s)")
      end
    end
  rescue
    e -> Logger.warning("reaper error: #{inspect(e)}")
  catch
    kind, reason -> Logger.warning("reaper crash: #{inspect({kind, reason})}")
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
