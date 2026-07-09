defmodule AetherS3.ControlPlane.Store do
  @behaviour AetherS3.ControlPlane

  # KHEPRI_WILDCARD_STAR — the #if_name_matches{regex = any} record as a tuple.
  # Matches any single child name, so [:users, @star] enumerates every user node.
  @star {:if_name_matches, :any, :undefined}
  @store :khepri
  @default_cp_timeout 5_000

  alias AetherS3.Auth.Grants
  alias AetherS3.ControlPlane.Cache

  @impl AetherS3.ControlPlane
  def create_bucket(name, owner) do
    result =
      cp_put([:buckets, name], %{
        created_at: DateTime.utc_now(),
        owner: owner,
        grants: [],
        scoped_grants: []
      })

    Cache.invalidate({:bucket, name})
    result
  end

  @impl AetherS3.ControlPlane
  def bucket_exists?(name), do: get_bucket(name) != nil

  @impl AetherS3.ControlPlane
  def get_bucket(name), do: Cache.fetch({:bucket, name}, fn -> cp_fetch([:buckets, name]) end)

  @impl AetherS3.ControlPlane
  def set_bucket_grants(name, grants) do
    case get_bucket(name) do
      nil ->
        {:error, :no_such_bucket}

      record ->
        result = cp_put([:buckets, name], record |> Map.put(:grants, grants) |> Map.delete(:acl))
        Cache.invalidate({:bucket, name})
        result
    end
  end

  @impl AetherS3.ControlPlane
  def set_bucket_acl(name, acl) do
    set_bucket_grants(name, Grants.canned(acl))
  end

  @impl AetherS3.ControlPlane
  def set_scoped_grants(name, scope, grants) do
    case get_bucket(name) do
      nil ->
        {:error, :no_such_bucket}

      record ->
        scoped = put_scope(Grants.scoped(record), scope, grants)
        result = cp_put([:buckets, name], Map.put(record, :scoped_grants, scoped))
        Cache.invalidate({:bucket, name})
        result
    end
  end

  # Upsert a scope's grants: replace an existing entry, append a new one, or (when
  # `grants` is empty — e.g. canned "private") drop the scope entirely.
  defp put_scope(scoped, scope, []), do: Enum.reject(scoped, &(&1.scope == scope))

  defp put_scope(scoped, scope, grants) do
    entry = %{scope: scope, grants: grants}

    if Enum.any?(scoped, &(&1.scope == scope)) do
      Enum.map(scoped, fn e -> if e.scope == scope, do: entry, else: e end)
    else
      [entry | scoped]
    end
  end

  @impl AetherS3.ControlPlane
  def delete_bucket(name) do
    case AetherS3.Replication.Coordinator.list(name) do
      [] ->
        result = cp_delete([:buckets, name])
        Cache.invalidate({:bucket, name})
        result

      _ ->
        {:error, :not_empty}
    end
  end

  @impl AetherS3.ControlPlane
  def put_user(name, admin) do
    result = cp_put([:users, name], %{admin: admin, created_at: DateTime.utc_now()})
    Cache.invalidate({:user, name})
    result
  end

  @impl AetherS3.ControlPlane
  def get_user(name), do: Cache.fetch({:user, name}, fn -> cp_fetch([:users, name]) end)

  @impl AetherS3.ControlPlane
  def put_key(access_key, user, secret_enc) do
    result =
      cp_put([:keys, access_key], %{
        user: user,
        secret_enc: secret_enc,
        created_at: DateTime.utc_now()
      })

    Cache.invalidate({:key, access_key})
    result
  end

  @impl AetherS3.ControlPlane
  def get_key(access_key),
    do: Cache.fetch({:key, access_key}, fn -> cp_fetch([:keys, access_key]) end)

  @impl AetherS3.ControlPlane
  def delete_key(access_key) do
    result = cp_delete([:keys, access_key])
    Cache.invalidate({:key, access_key})
    result
  end

  @impl AetherS3.ControlPlane
  def list_users, do: named(cp_get_many([:users, @star]))

  @impl AetherS3.ControlPlane
  def keys_of(user) do
    for {path, %{user: ^user}} <- cp_get_many([:keys, @star]), do: List.last(path)
  end

  @impl AetherS3.ControlPlane
  def delete_user(name) do
    # Cascade: a user's access keys go with them (each delete_key invalidates its
    # own cache entry).
    Enum.each(keys_of(name), &delete_key/1)
    result = cp_delete([:users, name])
    Cache.invalidate({:user, name})
    result
  end

  @impl AetherS3.ControlPlane
  def put_group(name, members) do
    result =
      cp_put([:groups, name], %{members: Enum.uniq(members), created_at: DateTime.utc_now()})

    Cache.invalidate_groups()
    result
  end

  @impl AetherS3.ControlPlane
  def get_group(name), do: cp_get([:groups, name])

  @impl AetherS3.ControlPlane
  def list_groups, do: named(cp_get_many([:groups, @star]))

  @impl AetherS3.ControlPlane
  def delete_group(name) do
    result = cp_delete([:groups, name])
    Cache.invalidate_groups()
    result
  end

  @impl AetherS3.ControlPlane
  def add_group_member(name, user) do
    case get_group(name) do
      nil -> {:error, :no_such_group}
      %{members: members} -> put_group(name, [user | members])
    end
  end

  @impl AetherS3.ControlPlane
  def remove_group_member(name, user) do
    case get_group(name) do
      nil -> {:error, :no_such_group}
      %{members: members} -> put_group(name, members -- [user])
    end
  end

  # Groups the user belongs to (scan-and-filter — fine at our scale). Cached per
  # user; any group write clears the whole group namespace (see invalidate_groups).
  @impl AetherS3.ControlPlane
  def groups_of(user) do
    Cache.fetch({:groups, user}, fn -> groups_of_cp(user) end)
  end

  defp groups_of_cp(user) do
    case :khepri.get_many(@store, [:groups, @star], read_opts()) do
      {:ok, map} ->
        {:ok, for({path, %{members: members}} <- map, user in members, do: List.last(path))}

      {:error, _} ->
        :error
    end
  end

  # --- bounded Khepri access ---
  #
  # Every control-plane command/query carries a timeout, so a wedged store (e.g.
  # stale Raft membership with no reachable leader) fails fast instead of hanging
  # forever: writes surface `{:error, :unavailable}` (the HTTP layer maps it to
  # 503) and reads degrade to nil/empty. Reads keep Khepri's default consistency
  # (a partitioned follower still resolves committed state via the leader once
  # reconnected — the minority's local state can lag a resync).

  defp cp_timeout, do: Application.get_env(:aether_s3, :cp_timeout, @default_cp_timeout)

  defp read_opts, do: %{timeout: cp_timeout()}

  defp cp_put(path, data) do
    case :khepri.put(@store, path, data, %{timeout: cp_timeout()}) do
      :ok -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp cp_delete(path) do
    case :khepri.delete(@store, path, %{timeout: cp_timeout()}) do
      :ok -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp cp_get(path) do
    case :khepri.get(@store, path, read_opts()) do
      {:ok, data} when is_map(data) -> data
      _ -> nil
    end
  end

  # Tri-state read for the cache: distinguish "reachable, absent" from "unreachable"
  # so the cache can serve stale on a CP outage but still report a genuine absence.
  #   {:ok, map} found | {:ok, nil} reachable-but-absent | :error unreachable
  defp cp_fetch(path) do
    case :khepri.get(@store, path, read_opts()) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:ok, nil}
      {:error, _} -> :error
    end
  end

  defp cp_get_many(pattern) do
    case :khepri.get_many(@store, pattern, read_opts()) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp named(map), do: Enum.map(map, fn {path, data} -> Map.put(data, :name, List.last(path)) end)
end
