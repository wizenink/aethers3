defmodule AetherS3.Storage.MultipartSession do
  use GenServer, restart: :temporary
  @ttl :timer.hours(1)

  def start_link(%{upload_id: id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via(id))
  end

  def via(upload_id), do: {:via, Registry, {AetherS3.UploadRegistry, upload_id}}

  def register_part(id, part_number, etag, size, path) do
    GenServer.call(via(id), {:register_part, part_number, etag, size, path})
  end

  def parts(id), do: GenServer.call(via(id), :parts)

  def complete(upload_id, requested_parts) do
    GenServer.call(via(upload_id), {:complete, requested_parts})
  end

  def abort(upload_id) do
    GenServer.stop(via(upload_id), :normal)
  end

  @impl true
  def init(arg) do
    state = Map.put(arg, :parts, %{})
    {:ok, state, @ttl}
  end

  @impl true
  def handle_call({:register_part, part_number, etag, size, path}, _from, state) do
    new_parts = Map.put(state.parts, part_number, %{etag: etag, size: size, path: path})
    {:reply, :ok, %{state | parts: new_parts}, @ttl}
  end

  @impl true
  def handle_call(:parts, _from, state) do
    {:reply, state.parts, state, @ttl}
  end

  @impl true
  def handle_call({:complete, requested}, _from, state) do
    result = validate_and_order(requested, state.parts)
    {:reply, result, state, @ttl}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.parts, fn {_pn, %{path: path}} -> File.rm(path) end)
    :ok
  end

  defp validate_and_order(requested, registered) do
    requested
    |> Enum.reduce_while({:ok, []}, fn {pn, etag}, {:ok, acc} ->
      case Map.get(registered, pn) do
        %{etag: ^etag, path: path} -> {:cont, {:ok, [path | acc]}}
        _ -> {:halt, {:error, :invalid_part}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end
end
