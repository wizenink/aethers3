defmodule AetherConsole.Cluster do
  @moduledoc """
  Reads live cluster state from the storage nodes' admin API (`GET /cluster`) over
  HTTP — the console is a pure client, no BEAM coupling.

  Any single node's `/cluster` response describes the whole cluster (membership,
  leader, per-node object counts), so we query the configured admin URLs and use
  the first that answers. Returns a normalized topology, or `%{connected: false}`
  when no node is reachable (the UI then falls back to its standalone animation).
  """

  @type node_view :: %{
          name: String.t(),
          up: boolean(),
          leader: boolean(),
          objects: non_neg_integer()
        }
  @type topology :: %{connected: boolean(), leader: String.t() | nil, nodes: [node_view()]}

  @spec snapshot() :: topology()
  def snapshot(urls \\ configured_urls()) do
    case Enum.find_value(urls, &fetch/1) do
      nil -> %{connected: false, leader: nil, nodes: []}
      data -> normalize(data)
    end
  end

  defp fetch(url) do
    case Req.get(String.trim_trailing(url, "/") <> "/cluster",
           receive_timeout: 1500,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> decode(body)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp decode(body) when is_map(body), do: body
  defp decode(body) when is_binary(body), do: Jason.decode!(body)

  defp normalize(%{"nodes" => nodes} = data) do
    leader = data["leader"]

    ns =
      for {name, view} <- nodes do
        %{
          name: name,
          up: not Map.has_key?(view, "error"),
          leader: name == leader,
          objects: Map.get(view, "objects", 0),
          ops: ops_of(view)
        }
      end
      |> Enum.sort_by(& &1.name)

    %{connected: true, leader: leader, nodes: ns}
  end

  defp normalize(_), do: %{connected: false, leader: nil, nodes: []}

  # Cumulative per-op counters from the node's local_view (absent on older nodes -> 0).
  defp ops_of(view) do
    o = Map.get(view, "ops") || %{}

    %{
      put: Map.get(o, "put", 0),
      repair: Map.get(o, "repair", 0),
      read_repair: Map.get(o, "read_repair", 0),
      shed: Map.get(o, "shed", 0)
    }
  end

  defp configured_urls do
    Application.get_env(:aether_console, :cluster_nodes, ["http://localhost:9001"])
  end
end
