defmodule AetherS3.Cluster.RingServer do
  use GenServer
  require Logger
  alias AetherS3.Cluster.Ring

  @pt_key {__MODULE__, :members}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def members, do: :persistent_term.get(@pt_key, [Node.self()])
  def default_n, do: Application.get_env(:aether_s3, :replication_factor, 3)
  def replicas(key, n \\ default_n()), do: Ring.replicas(key, members(), n)

  @impl true
  def init(:ok) do
    :ok = :net_kernel.monitor_nodes(true)
    update_members()
    {:ok, %{}}
  end

  @impl true
  def handle_info({event, _node}, state) when event in [:nodeup, :nodedown] do
    update_members()
    {:noreply, state}
  end

  defp update_members do
    members = Enum.sort([Node.self() | Node.list()])
    :persistent_term.put(@pt_key, members)
    Logger.info("cluster membership (#{length(members)}): #{inspect(members)}")
  end
end
