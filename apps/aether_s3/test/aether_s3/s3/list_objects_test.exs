defmodule AetherS3.S3.ListObjectsTest do
  use ExUnit.Case, async: true

  alias AetherS3.S3.ListObjects

  # A sorted [{key, meta}] like Coordinator.list/1 returns. meta content is opaque here.
  defp entries(keys), do: Enum.map(keys, fn k -> {k, %{size: 1}} end)

  defp keys(result), do: Enum.map(result.keys, fn {k, _m} -> k end)

  defp tree do
    entries([
      "a.txt",
      "docs/1.txt",
      "docs/2.txt",
      "docs/sub/x.txt",
      "photos/cat.jpg",
      "photos/dog.jpg",
      "z.txt"
    ])
  end

  test "no options returns every key, sorted, not truncated" do
    r = ListObjects.paginate(tree())
    assert keys(r) == Enum.map(tree(), &elem(&1, 0))
    assert r.common_prefixes == []
    refute r.truncated
    assert r.key_count == 7
  end

  test "prefix filters to the matching subtree" do
    r = ListObjects.paginate(tree(), prefix: "photos/")
    assert keys(r) == ["photos/cat.jpg", "photos/dog.jpg"]
  end

  test "delimiter folds a level into common prefixes; both count toward the page" do
    r = ListObjects.paginate(tree(), delimiter: "/")
    # top-level files stay as keys; nested keys collapse to first-segment prefixes
    assert keys(r) == ["a.txt", "z.txt"]
    assert r.common_prefixes == ["docs/", "photos/"]
    assert r.key_count == 4
  end

  test "prefix + delimiter lists one directory level under the prefix" do
    r = ListObjects.paginate(tree(), prefix: "docs/", delimiter: "/")
    assert keys(r) == ["docs/1.txt", "docs/2.txt"]
    assert r.common_prefixes == ["docs/sub/"]
  end

  test "max_keys truncates and yields a resume cursor; the next page continues" do
    p1 = ListObjects.paginate(tree(), max_keys: 3)
    assert keys(p1) == ["a.txt", "docs/1.txt", "docs/2.txt"]
    assert p1.truncated
    assert p1.next_token == "docs/2.txt"

    p2 = ListObjects.paginate(tree(), max_keys: 3, after: p1.next_token)
    assert keys(p2) == ["docs/sub/x.txt", "photos/cat.jpg", "photos/dog.jpg"]
    assert p2.truncated
    assert p2.next_token == "photos/dog.jpg"

    p3 = ListObjects.paginate(tree(), max_keys: 3, after: p2.next_token)
    assert keys(p3) == ["z.txt"]
    refute p3.truncated
    assert p3.next_token == nil
  end

  test "a common prefix serves as its own resume cursor across pages" do
    p1 = ListObjects.paginate(tree(), delimiter: "/", max_keys: 2)
    # rows sorted: "a.txt", "docs/", "photos/", "z.txt"
    assert keys(p1) == ["a.txt"]
    assert p1.common_prefixes == ["docs/"]
    assert p1.truncated
    assert p1.next_token == "docs/"

    p2 = ListObjects.paginate(tree(), delimiter: "/", max_keys: 2, after: p1.next_token)
    assert p2.common_prefixes == ["photos/"]
    assert keys(p2) == ["z.txt"]
    refute p2.truncated
  end

  test "max_keys is clamped to [0, 1000]; a bad value falls back to the default" do
    assert ListObjects.paginate(tree(), max_keys: 99_999).max_keys == 1000
    assert ListObjects.paginate(tree(), max_keys: "oops").max_keys == 1000
    assert ListObjects.paginate(tree(), max_keys: 0).key_count == 0
  end

  test "empty bucket is an empty, non-truncated page" do
    r = ListObjects.paginate([])
    assert r.keys == []
    assert r.common_prefixes == []
    refute r.truncated
    assert r.next_token == nil
  end
end
