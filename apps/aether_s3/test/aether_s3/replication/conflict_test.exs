defmodule AetherS3.Replication.ConflictTest do
  use ExUnit.Case, async: true

  alias AetherS3.Replication.Conflict

  @t ~U[2026-01-01 00:00:00Z]
  defp m(vv, opts \\ []) do
    %{
      vv: vv,
      etag: Keyword.get(opts, :etag, inspect(vv)),
      last_modified: Keyword.get(opts, :lm, @t)
    }
  end

  test "causal descendant wins" do
    old = m(%{a: 1})
    new = m(%{a: 1, b: 1})
    assert Conflict.winner(old, new) == new
    assert Conflict.winner(new, old) == new
  end

  test "supersedes?: newer over older, and over missing" do
    old = m(%{a: 1})
    new = m(%{a: 1, b: 1})
    assert Conflict.supersedes?(new, old)
    refute Conflict.supersedes?(old, new)
    assert Conflict.supersedes?(new, nil)
  end

  test "identical version does not supersede (no flapping re-push)" do
    v = m(%{a: 1})
    refute Conflict.supersedes?(v, v)
    refute Conflict.supersedes?(v, m(%{a: 1}))
  end

  test "concurrent versions resolve by the deterministic tiebreak" do
    a = m(%{a: 1}, etag: "zzz")
    b = m(%{b: 1}, etag: "aaa")
    # same last_modified -> higher etag wins
    assert Conflict.winner(a, b) == a
    assert Conflict.supersedes?(a, b)
    refute Conflict.supersedes?(b, a)
  end

  test "legacy vv-less metas fall back to LWW by last_modified" do
    old = %{etag: "old", last_modified: ~U[2026-01-01 00:00:00Z]}
    new = %{etag: "new", last_modified: ~U[2026-01-02 00:00:00Z]}
    assert Conflict.winner(old, new) == new
    assert Conflict.supersedes?(new, old)
    refute Conflict.supersedes?(old, new)
  end
end
