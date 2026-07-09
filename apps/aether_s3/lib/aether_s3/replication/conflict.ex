defmodule AetherS3.Replication.Conflict do
  @moduledoc """
  Meta-level conflict resolution, layered on `VersionVector`. A causal descendant
  wins; genuinely concurrent versions (and legacy vv-less metas) fall back to a
  deterministic tiebreak — last-writer-wins by `last_modified`, then `etag`.

  `supersedes?/2` is the single predicate the replication paths use: "should this
  version overwrite what a replica currently holds?" (read-repair, anti-entropy,
  and the rebalance shed pass all phrase their decisions in terms of it).
  """
  alias AetherS3.Replication.VersionVector, as: VV

  @doc "This meta's version vector (missing = empty, for backward compat)."
  def vv(meta), do: Map.get(meta, :vv, %{})

  @doc "The winning meta of two versions of the same key."
  def winner(a, b) do
    case VV.compare(vv(a), vv(b)) do
      :gt -> a
      :lt -> b
      # :eq (same version) or :concurrent (true conflict, or legacy vv-less) — LWW.
      _ -> tiebreak(a, b)
    end
  end

  @doc """
  Should `a`'s version replace what a replica currently holds as `b`? `b` is `nil`
  when the replica is missing the object. True iff `a` wins and is a different
  version (never re-push an identical copy, which would flap).
  """
  def supersedes?(_a, nil), do: true
  def supersedes?(a, b), do: winner(a, b) == a and not same_version?(a, b)

  defp same_version?(a, b), do: vv(a) == vv(b) and Map.get(a, :etag) == Map.get(b, :etag)

  defp tiebreak(a, b) do
    case DateTime.compare(a.last_modified, b.last_modified) do
      :gt -> a
      :lt -> b
      :eq -> if Map.get(a, :etag, "") >= Map.get(b, :etag, ""), do: a, else: b
    end
  end
end
