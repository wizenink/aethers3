defmodule AetherS3.ControlPlane.Store do
  @behaviour AetherS3.ControlPlane

  # KHEPRI_WILDCARD_STAR — the #if_name_matches{regex = any} record as a tuple.
  # Matches any single child name, so [:users, @star] enumerates every user node.
  @star {:if_name_matches, :any, :undefined}
  @store :khepri
  @default_cp_timeout 5_000

  alias AetherS3.Auth.Grants

  @impl AetherS3.ControlPlane
  def create_bucket(name, owner) do
    cp_put([:buckets, name], %{
      created_at: DateTime.utc_now(),
      owner: owner,
      grants: [],
      scoped_grants: []
    })
  end

  @impl AetherS3.ControlPlane
  def bucket_exists?(name) do
    match?(true, :khepri.exists(@store, [:buckets, name], read_opts()))
  end

  @impl AetherS3.ControlPlane
  def get_bucket(name), do: cp_get([:buckets, name])

  @impl AetherS3.ControlPlane
  def set_bucket_grants(name, grants) do
    case get_bucket(name) do
      nil -> {:error, :no_such_bucket}
      record -> cp_put([:buckets, name], record |> Map.put(:grants, grants) |> Map.delete(:acl))
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
        cp_put([:buckets, name], Map.put(record, :scoped_grants, scoped))
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
      [] -> cp_delete([:buckets, name])
      _ -> {:error, :not_empty}
    end
  end

  @impl AetherS3.ControlPlane
  def put_user(name, admin) do
    cp_put([:users, name], %{admin: admin, created_at: DateTime.utc_now()})
  end

  @impl AetherS3.ControlPlane
  def get_user(name), do: cp_get([:users, name])

  @impl AetherS3.ControlPlane
  def put_key(access_key, user, secret_enc) do
    cp_put([:keys, access_key], %{
      user: user,
      secret_enc: secret_enc,
      created_at: DateTime.utc_now()
    })
  end

  @impl AetherS3.ControlPlane
  def get_key(access_key), do: cp_get([:keys, access_key])

  @impl AetherS3.ControlPlane
  def delete_key(access_key), do: cp_delete([:keys, access_key])

  @impl AetherS3.ControlPlane
  def list_users, do: named(cp_get_many([:users, @star]))

  @impl AetherS3.ControlPlane
  def keys_of(user) do
    for {path, %{user: ^user}} <- cp_get_many([:keys, @star]), do: List.last(path)
  end

  @impl AetherS3.ControlPlane
  def delete_user(name) do
    # Cascade: a user's access keys go with them.
    Enum.each(keys_of(name), &delete_key/1)
    cp_delete([:users, name])
  end

  @impl AetherS3.ControlPlane
  def put_group(name, members) do
    cp_put([:groups, name], %{members: Enum.uniq(members), created_at: DateTime.utc_now()})
  end

  @impl AetherS3.ControlPlane
  def get_group(name), do: cp_get([:groups, name])

  @impl AetherS3.ControlPlane
  def list_groups, do: named(cp_get_many([:groups, @star]))

  @impl AetherS3.ControlPlane
  def delete_group(name), do: cp_delete([:groups, name])

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

  # Groups the user belongs to (scan-and-filter — fine at our scale).
  @impl AetherS3.ControlPlane
  def groups_of(user) do
    for {path, %{members: members}} <- cp_get_many([:groups, @star]),
        user in members,
        do: List.last(path)
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

  defp cp_get_many(pattern) do
    case :khepri.get_many(@store, pattern, read_opts()) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp named(map), do: Enum.map(map, fn {path, data} -> Map.put(data, :name, List.last(path)) end)
end
