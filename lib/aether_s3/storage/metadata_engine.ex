defmodule AetherS3.Storage.MetadataEngine do
  use GenServer

  # ===== Client API =====
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{buckets: MapSet.new(), objects: %{}}, name: __MODULE__)
  end

  def put_object(bucket, key, meta) do
    GenServer.call(__MODULE__, {:put_object, bucket, key, meta})
  end

  def get_object(bucket, key) do
    GenServer.call(__MODULE__, {:get_object, bucket, key})
  end

  def delete_object(bucket, key) do
    GenServer.call(__MODULE__, {:delete_object, bucket, key})
  end

  def list_objects(bucket) do
    GenServer.call(__MODULE__, {:list_objects, bucket})
  end

  def create_bucket(name) do
    GenServer.call(__MODULE__, {:create_bucket, name})
  end

  def bucket_exists?(name) do
    GenServer.call(__MODULE__, {:bucket_exists?, name})
  end

  def delete_bucket(name) do
    GenServer.call(__MODULE__, {:delete_bucket, name})
  end

  # ===== Server callbacks =====
  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:put_object, bucket, key, meta}, _from, state) do
    new_state = %{state | objects: Map.put(state.objects, {bucket, key}, meta)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_object, bucket, key}, _from, state) do
    reply =
      case Map.get(state.objects, {bucket, key}) do
        nil -> :not_found
        meta -> {:ok, meta}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:delete_object, bucket, key}, _from, state) do
    new_state = %{state | objects: Map.delete(state.objects, {bucket, key})}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:list_objects, bucket}, _from, state) do
    keys =
      state.objects
      |> Enum.filter(fn {{b, _k}, _meta} -> b == bucket end)
      |> Enum.map(fn {{_b, k}, meta} -> {k, meta} end)

    {:reply, keys, state}
  end

  @impl true
  def handle_call({:create_bucket, name}, _from, state) do
    new_state = %{state | buckets: MapSet.put(state.buckets, name)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:bucket_exists?, name}, _from, state) do
    {:reply, MapSet.member?(state.buckets, name), state}
  end

  @impl true
  def handle_call({:delete_bucket, name}, _from, state) do
    has_objects? = Enum.any?(Map.keys(state.objects), fn {b, _k} -> b == name end)

    if has_objects? do
      {:reply, {:error, :not_empty}, state}
    else
      {:reply, :ok, %{state | buckets: MapSet.delete(state.buckets, name)}}
    end
  end
end
