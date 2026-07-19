defmodule AetherS3.ObjectMeta.Store do
  @behaviour AetherS3.ObjectMeta
  @db AetherS3.ObjectMeta.DB

  @impl AetherS3.ObjectMeta
  def put(bucket, key, meta) do
    :ok = CubDB.put(@db, {bucket, key}, meta)
    # Block until the write is durable. In group-commit mode this coalesces the
    # fsync with other in-flight writers; in :each mode CubDB already fsynced and
    # this returns immediately.
    AetherS3.ObjectMeta.GroupCommit.sync()
  end

  @impl AetherS3.ObjectMeta
  def get(bucket, key) do
    case CubDB.get(@db, {bucket, key}) do
      nil -> :not_found
      meta -> {:ok, meta}
    end
  end

  @impl AetherS3.ObjectMeta
  def delete(bucket, key) do
    CubDB.delete(@db, {bucket, key})
  end

  @impl AetherS3.ObjectMeta
  def list(bucket) do
    @db
    |> CubDB.select(min_key: {bucket, ""}, max_key: {bucket, <<255>>})
    |> Enum.map(fn {{_b, k}, meta} -> {k, meta} end)
  end

  def all do
    AetherS3.ObjectMeta.DB
    |> CubDB.select(min_key: {<<>>, <<>>}, max_key: {<<255>>, <<255>>})
    |> Enum.map(fn {{bucket, key}, meta} -> {bucket, key, meta} end)
  end

  @doc "Number of object-metadata entries held locally (cheap; for metrics)."
  def count, do: CubDB.size(@db)
end
