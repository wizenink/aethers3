defmodule AetherS3.ControlPlane.CacheTest do
  # Mutates the shared cp_cache_ttl_ms env + the named ETS table -> not async.
  use ExUnit.Case, async: false

  alias AetherS3.ControlPlane.Cache

  setup do
    prev = Application.fetch_env(:aether_s3, :cp_cache_ttl_ms)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:aether_s3, :cp_cache_ttl_ms, v)
        :error -> Application.delete_env(:aether_s3, :cp_cache_ttl_ms)
      end
    end)

    # Unique key per test — the cache table is shared across the suite.
    {:ok, key: {:cache_test, System.unique_integer([:positive])}}
  end

  defp ttl(ms), do: Application.put_env(:aether_s3, :cp_cache_ttl_ms, ms)
  defp counter, do: :counters.new(1, [])
  defp count(c), do: :counters.get(c, 1)
  defp counting(c, value), do: fn -> :counters.add(c, 1, 1) && {:ok, value} end

  test "a fresh hit within TTL does not call the fetcher again", %{key: key} do
    ttl(10_000)
    c = counter()
    assert Cache.fetch(key, counting(c, :v)) == :v
    assert Cache.fetch(key, counting(c, :v)) == :v
    assert count(c) == 1
  end

  test "an expired entry re-fetches", %{key: key} do
    ttl(5)
    c = counter()
    assert Cache.fetch(key, counting(c, :v)) == :v
    Process.sleep(15)
    assert Cache.fetch(key, counting(c, :v)) == :v
    assert count(c) == 2
  end

  test "serves the last known-good value when the CP is unreachable", %{key: key} do
    ttl(5)
    assert Cache.fetch(key, fn -> {:ok, :good} end) == :good
    Process.sleep(15)
    # entry is now stale AND the CP read fails -> serve stale rather than fail
    assert Cache.fetch(key, fn -> :error end) == :good
  end

  test "an unreachable CP with no prior value resolves to nil (fails closed)", %{key: key} do
    ttl(1_000)
    assert Cache.fetch(key, fn -> :error end) == nil
  end

  test "caches an absent (nil) result so repeated misses don't hit the CP", %{key: key} do
    ttl(10_000)
    c = counter()
    assert Cache.fetch(key, counting(c, nil)) == nil
    assert Cache.fetch(key, counting(c, nil)) == nil
    assert count(c) == 1
  end

  test "invalidate/1 forces the next read to re-fetch", %{key: key} do
    ttl(10_000)
    c = counter()
    Cache.fetch(key, counting(c, :v))
    Cache.invalidate(key)
    Cache.fetch(key, counting(c, :v))
    assert count(c) == 2
  end

  test "invalidate_groups/0 clears only {:groups, _} entries" do
    ttl(10_000)
    gkey = {:groups, "u#{System.unique_integer([:positive])}"}
    bkey = {:bucket, "b#{System.unique_integer([:positive])}"}
    gc = counter()
    bc = counter()

    Cache.fetch(gkey, counting(gc, [:g]))
    Cache.fetch(bkey, counting(bc, :b))
    Cache.invalidate_groups()

    Cache.fetch(gkey, counting(gc, [:g]))
    Cache.fetch(bkey, counting(bc, :b))

    assert count(gc) == 2, "group entry should have been cleared"
    assert count(bc) == 1, "bucket entry should have survived"
  end

  test "ttl <= 0 disables caching (always fetches)", %{key: key} do
    ttl(0)
    c = counter()
    Cache.fetch(key, counting(c, :v))
    Cache.fetch(key, counting(c, :v))
    assert count(c) == 2
  end
end
