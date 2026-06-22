defmodule AetherS3.Replication.AntiEntropy do
  @moduledoc """
  Push-based, LWW convergence of object replicas
  """
  alias AetherS3.Cluster.RingServer
  alias AetherS3.Replication.Coordinator
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta

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

  def reconcile do
    Enum.each(ObjectMeta.all(), fn {bucket, key, meta} -> repair(bucket, key, meta) end)
  end

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
