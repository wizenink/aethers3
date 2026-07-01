defmodule AetherS3.Replication.VersionVector do
  @moduledoc """
  Version vectors for causal conflict resolution. A VV maps each writer node to a
  monotonic counter; comparing two tells us whether one causally descends from the
  other (a real update) or they're concurrent (a true conflict).
  """
  @type t :: %{node() => non_neg_integer()}

  @spec new() :: t()
  def new, do: %{}

  @doc "Record a new event by `node` (its counter +1), descending from `vv`."
  @spec increment(t(), node()) :: t()
  def increment(vv, node), do: Map.update(vv, node, 1, &(&1 + 1))

  @doc "Does `a` contain all of `b`'s history? (a[k] >= b[k] for every k in b)"
  @spec descends_or_equal?(t(), t()) :: boolean()
  def descends_or_equal?(a, b) do
    Enum.all?(b, fn {node, count} -> Map.get(a, node, 0) >= count end)
  end

  @doc "Is `a` strictly causally after `b`?"
  @spec dominates?(t(), t()) :: boolean()
  def dominates?(a, b), do: descends_or_equal?(a, b) and a != b

  @doc "Neither descends from the other → a true conflict."
  @spec concurrent?(t(), t()) :: boolean()
  def concurrent?(a, b), do: not descends_or_equal?(a, b) and not descends_or_equal?(b, a)

  @doc ":gt (a newer) | :lt (b newer) | :eq | :concurrent"
  @spec compare(t(), t()) :: :gt | :lt | :eq | :concurrent
  def compare(a, b) do
    cond do
      a == b -> :eq
      dominates?(a, b) -> :gt
      dominates?(b, a) -> :lt
      true -> :concurrent
    end
  end
end
