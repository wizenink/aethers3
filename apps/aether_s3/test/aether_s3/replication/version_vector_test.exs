defmodule AetherS3.Replication.VersionVectorTest do
  use ExUnit.Case, async: true

  alias AetherS3.Replication.VersionVector, as: VV

  test "increment creates and bumps a node's counter" do
    assert VV.increment(VV.new(), :a) == %{a: 1}
    assert VV.increment(%{a: 1}, :a) == %{a: 2}
    assert VV.increment(%{a: 1}, :b) == %{a: 1, b: 1}
  end

  test "descends_or_equal? checks containment of history (missing = 0)" do
    assert VV.descends_or_equal?(%{a: 2, b: 1}, %{a: 1, b: 1})
    assert VV.descends_or_equal?(%{a: 1}, %{})
    assert VV.descends_or_equal?(%{a: 1}, %{a: 1})
    refute VV.descends_or_equal?(%{a: 1}, %{a: 2})
    refute VV.descends_or_equal?(%{a: 1}, %{b: 1})
  end

  describe "compare/2" do
    test "a causal update is :gt / :lt" do
      assert VV.compare(%{a: 2}, %{a: 1}) == :gt
      assert VV.compare(%{a: 1}, %{a: 1, b: 1}) == :lt
    end

    test "identical vectors are :eq" do
      assert VV.compare(%{a: 1, b: 1}, %{a: 1, b: 1}) == :eq
      assert VV.compare(%{}, %{}) == :eq
    end

    test "divergent writes are :concurrent" do
      assert VV.compare(%{a: 1}, %{b: 1}) == :concurrent
      assert VV.compare(%{a: 2, b: 1}, %{a: 1, b: 2}) == :concurrent
    end
  end

  test "dominates? is strict (not reflexive) and concurrent? is symmetric" do
    refute VV.dominates?(%{a: 1}, %{a: 1})
    assert VV.dominates?(%{a: 2}, %{a: 1})
    assert VV.concurrent?(%{a: 1}, %{b: 1})
    assert VV.concurrent?(%{b: 1}, %{a: 1})
    refute VV.concurrent?(%{a: 2}, %{a: 1})
  end
end
