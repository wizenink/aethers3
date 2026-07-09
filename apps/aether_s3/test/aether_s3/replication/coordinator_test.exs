defmodule AetherS3.Replication.CoordinatorTest do
  use ExUnit.Case, async: true

  alias AetherS3.Replication.Coordinator

  @t ~U[2026-01-01 00:00:00Z]

  # meta carrying a version vector (and an etag derived from it so distinct
  # versions look like distinct content).
  defp meta(vv), do: %{last_modified: @t, size: 1, etag: inspect(vv), content_type: "x", vv: vv}

  test "plan/2 returns :not_found when no replica has the object" do
    results = [{:a, :not_found}, {:b, :not_found}]
    assert Coordinator.plan([:a, :b], results) == :not_found
  end

  test "plan/2 with all replicas at the same version has no repair targets" do
    v = meta(%{a: 1})
    results = [{:a, {:ok, v}}, {:b, {:ok, v}}, {:c, {:ok, v}}]
    {winner, _meta, targets} = Coordinator.plan([:a, :b, :c], results)
    assert winner in [:a, :b, :c]
    assert targets == []
  end

  test "plan/2 picks the causally-latest version and flags older + missing replicas" do
    old = meta(%{a: 1})
    # :b's version descends :a's (a wrote v1, b overwrote -> {a:1,b:1})
    new = meta(%{a: 1, b: 1})
    results = [{:a, {:ok, old}}, {:b, {:ok, new}}, {:c, :not_found}]
    {winner, winner_meta, targets} = Coordinator.plan([:a, :b, :c], results)

    assert winner == :b
    assert winner_meta.vv == %{a: 1, b: 1}
    # :a holds the older version, :c is missing; :b (the winner) is never a target
    assert Enum.sort(targets) == [:a, :c]
  end

  test "plan/2 never repairs an unreachable (:error) replica, only a reachable-absent one" do
    # :b is reachable-but-absent (:not_found) -> a legit repair target.
    # :c is unreachable (:error) -> state unknown, must NOT be a target, even though
    # supersedes?(winner, nil) is true. Treating "unknown" as "absent" is exactly what
    # let a stale write clobber a newer one on partition heal.
    v = meta(%{a: 1})
    results = [{:a, {:ok, v}}, {:b, :not_found}, {:c, :error}]
    {winner, _meta, targets} = Coordinator.plan([:a, :b, :c], results)

    assert winner == :a
    assert targets == [:b]
  end

  test "plan/2 resolves a true conflict (concurrent VVs) deterministically" do
    # {a:1} and {b:1} are concurrent -> winner decided by the etag tiebreak.
    ca = meta(%{a: 1})
    cb = meta(%{b: 1})
    results = [{:a, {:ok, ca}}, {:b, {:ok, cb}}]
    {winner, _meta, targets} = Coordinator.plan([:a, :b], results)
    assert winner in [:a, :b]
    # the loser is repaired to the winner's version
    assert targets == [if(winner == :a, do: :b, else: :a)]
  end

  describe "resolve_w/2 (write quorum)" do
    test "integer W is used as-is and clamped to [1, n]" do
      assert Coordinator.resolve_w(3, 1) == 1
      assert Coordinator.resolve_w(3, 2) == 2
      assert Coordinator.resolve_w(3, 5) == 3
      assert Coordinator.resolve_w(3, 0) == 1
    end

    test ":quorum is a majority, :all is every replica" do
      assert Coordinator.resolve_w(3, :quorum) == 2
      assert Coordinator.resolve_w(4, :quorum) == 3
      assert Coordinator.resolve_w(3, :all) == 3
    end
  end
end
