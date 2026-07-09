defmodule AetherS3.ControlPlane.Cache do
  @moduledoc """
  A small read-through cache in front of the hot control-plane reads (credential,
  identity, bucket, and group lookups) so an authenticated object request doesn't
  pay a Raft/leader round-trip — and stays serviceable when the CP is briefly
  unreachable.

  Every authenticated S3 request resolves the access key → secret (auth), the
  user's admin flag + groups (principals), and the bucket's owner + grants
  (authz). Those all live in Khepri, so without a cache every GET/PUT does 3–4
  leader-routed reads. This caches each result with a short TTL.

  ## Freshness vs availability

    * **Fresh** (within TTL): served from ETS, no CP read.
    * **Expired, CP reachable**: refreshed from the CP.
    * **Expired, CP unreachable**: the last known-good value is served (**serve
      stale**). This is what keeps a partitioned-minority node authenticating and
      authorizing requests for objects it already holds instead of failing closed.

  The cost is bounded staleness: a revoked key or changed grant takes up to one
  TTL to be observed on a node that didn't make the change (and until reconnect on
  a partitioned node). Writes on *this* node invalidate the affected entry
  immediately (see `invalidate/1`); cross-node propagation is TTL-bounded.

  The fetcher distinguishes the three outcomes so "unreachable" is never mistaken
  for "absent":

      {:ok, value}  # reachable — found (value) or absent (nil)
      :error        # unreachable / CP read failed
  """
  use GenServer

  @table __MODULE__
  @default_ttl_ms 1_000
  # Soft cap so an attacker probing random access keys can't grow the table without
  # bound; past it we stop inserting new entries (existing ones still refresh).
  @max_entries 50_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Read-through fetch. `fetcher` is a 0-arity fun returning `{:ok, value}` (value
  may be `nil` for a reachable-but-absent node) or `:error` (CP unreachable).
  Returns the resolved value (possibly `nil`).
  """
  @spec fetch(term(), (-> {:ok, term()} | :error)) :: term()
  def fetch(key, fetcher) do
    ttl = ttl_ms()

    if ttl <= 0 or :ets.whereis(@table) == :undefined do
      # Cache disabled (or not started, e.g. a bare unit test) — pass through.
      resolve(fetcher)
    else
      case :ets.lookup(@table, key) do
        [{^key, value, at}] ->
          if now_ms() - at < ttl, do: value, else: refresh(key, fetcher, {:some, value})

        [] ->
          refresh(key, fetcher, :none)
      end
    end
  end

  @doc "Drop a cached entry so the next read re-fetches (used on same-node writes)."
  def invalidate(key) do
    if started?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc "Drop every cached group lookup (a group-membership change can affect many users)."
  def invalidate_groups do
    if started?(), do: :ets.match_delete(@table, {{:groups, :_}, :_, :_})
    :ok
  end

  @doc "Drop the whole cache."
  def invalidate_all do
    if started?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  # --- internals ---

  defp refresh(key, fetcher, fallback) do
    case fetcher.() do
      {:ok, value} ->
        maybe_insert(key, value)
        value

      :error ->
        # CP unreachable: serve the last known-good value if we have one, else
        # behave as absent (nil) — which fails auth closed / reads as no-bucket.
        case fallback do
          {:some, value} -> value
          :none -> nil
        end
    end
  end

  # Cache-off path: just run the fetcher, no store, no stale-serving.
  defp resolve(fetcher) do
    case fetcher.() do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp maybe_insert(key, value) do
    if :ets.info(@table, :size) < @max_entries or :ets.member(@table, key) do
      :ets.insert(@table, {key, value, now_ms()})
    end
  end

  defp started?, do: :ets.whereis(@table) != :undefined

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ttl_ms, do: Application.get_env(:aether_s3, :cp_cache_ttl_ms, @default_ttl_ms)
end
