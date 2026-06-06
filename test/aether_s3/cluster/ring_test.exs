defmodule AetherS3.Cluster.RingTest do
  use ExUnit.Case, async: true

  alias AetherS3.Cluster.Ring

  @members [:a@h, :b@h, :c@h, :d@h, :e@h]
  @keys for i <- 1..10_000, do: "bucket/object-#{i}"

  test "replica set is deterministic for the same key and members" do
    for key <- ["x", "y", "photos/cat.jpg"] do
      assert Ring.replicas(key, @members, 3) == Ring.replicas(key, @members, 3)
    end
  end

  test "every node computes the same placement regardless of input order" do
    shuffled = Enum.shuffle(@members)

    assert Ring.replicas("photos/cat.jpg", @members, 3) ==
             Ring.replicas("photos/cat.jpg", shuffled, 3)
  end

  test "replica set has n distinct nodes, all members, clamped to cluster size" do
    rs = Ring.replicas("k", @members, 3)
    assert length(rs) == 3
    assert Enum.uniq(rs) == rs
    assert Enum.all?(rs, &(&1 in @members))

    # asking for more replicas than nodes returns all nodes, no crash
    assert Enum.sort(Ring.replicas("k", @members, 99)) == Enum.sort(@members)
  end

  test "primary is the head of the replica set" do
    assert Ring.primary("k", @members) == hd(Ring.replicas("k", @members, 1))
  end

  test "keys are distributed roughly evenly across nodes (within 15%)" do
    counts = Enum.frequencies_by(@keys, &Ring.primary(&1, @members))
    expected = length(@keys) / length(@members)

    for node <- @members do
      got = Map.get(counts, node, 0)
      assert_in_delta got, expected, expected * 0.15
    end
  end

  test "adding a node reshuffles only ~1/N of keys (minimal disruption)" do
    before = Map.new(@keys, fn k -> {k, Ring.primary(k, @members)} end)

    grown = [:f@h | @members]
    moved = Enum.count(@keys, fn k -> Ring.primary(k, grown) != before[k] end)

    fraction = moved / length(@keys)
    # With 6 nodes, ideal reshuffle on join is 1/6 ≈ 0.167. Allow generous slack.
    assert fraction < 0.25,
           "expected ~1/6 of keys to move, but #{Float.round(fraction * 100, 1)}% did"

    # Sanity: it should actually move a meaningful (non-zero) chunk too.
    assert fraction > 0.10
  end
end
