defmodule AetherS3.Replication.CoordinatorTest do
  use ExUnit.Case, async: true

  alias AetherS3.Replication.Coordinator

  defp meta(t), do: %{last_modified: t, size: 1, etag: "e", content_type: "text/plain"}

  @old ~U[2026-01-01 00:00:00Z]
  @new ~U[2026-01-02 00:00:00Z]

  test "plan/2 returns :not_found when no replica has the object" do
    results = [{:a, :not_found}, {:b, :not_found}]
    assert Coordinator.plan([:a, :b], results) == :not_found
  end

  test "plan/2 with all replicas in sync has no repair targets" do
    results = [{:a, {:ok, meta(@old)}}, {:b, {:ok, meta(@old)}}, {:c, {:ok, meta(@old)}}]
    {winner, _meta, targets} = Coordinator.plan([:a, :b, :c], results)
    assert winner in [:a, :b, :c]
    assert targets == []
  end

  test "plan/2 picks the LWW winner and flags stale + missing replicas" do
    results = [{:a, {:ok, meta(@old)}}, {:b, {:ok, meta(@new)}}, {:c, :not_found}]
    {winner, winner_meta, targets} = Coordinator.plan([:a, :b, :c], results)

    assert winner == :b
    assert winner_meta.last_modified == @new
    # :a is stale, :c is missing; :b (the winner) is never a target
    assert Enum.sort(targets) == [:a, :c]
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
