defmodule AetherS3.Cluster.Ring do
  @moduledoc """
  Rendezvous (Highest-Random-Weight) hashing. Pure functions over the current
  member list — every node computes the same placement without coordination.
  """

  @doc "Ordered replica set for `key`. Head is primary. Returns up to `n` nodes"
  def replicas(key, members, n) do
    members
    |> Enum.sort_by(fn node -> {weight(node, key), node} end, :desc)
    |> Enum.take(n)
  end

  def primary(key, members), do: key |> replicas(members, 1) |> List.first()

  def owns?(node, key, members, n), do: node in replicas(key, members, n)

  defp weight(node, key), do: :erlang.phash2({node, key})
end
