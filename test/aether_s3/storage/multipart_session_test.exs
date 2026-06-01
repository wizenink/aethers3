defmodule AetherS3.Storage.MultipartSessionTest do
  use ExUnit.Case, async: false

  alias AetherS3.Storage.MultipartSession, as: MP

  setup do
    id = "test-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        AetherS3.UploadSupervisor,
        {MP, %{upload_id: id, bucket: "b", key: "k"}}
      )

    on_exit(fn ->
      case GenServer.whereis(MP.via(id)) do
        nil -> :ok
        _ -> MP.abort(id)
      end
    end)

    {:ok, id: id}
  end

  test "registers parts and lists them back", %{id: id} do
    assert :ok == MP.register_part(id, 1, "e1", 100, "/tmp/x1")
    assert :ok == MP.register_part(id, 2, "e2", 200, "/tmp/x2")
    assert MP.parts(id) |> Map.keys() |> Enum.sort() == [1, 2]
  end

  test "complete validates etags and returns paths in requested order", %{id: id} do
    MP.register_part(id, 1, "e1", 1, "/tmp/p1")
    MP.register_part(id, 2, "e2", 1, "/tmp/p2")
    assert {:ok, ["/tmp/p1", "/tmp/p2"]} == MP.complete(id, [{1, "e1"}, {2, "e2"}])
    assert {:ok, ["/tmp/p2", "/tmp/p1"]} == MP.complete(id, [{2, "e2"}, {1, "e1"}])
  end

  test "complete rejects a wrong etag", %{id: id} do
    MP.register_part(id, 1, "e1", 1, "/tmp/p1")
    assert {:error, :invalid_part} == MP.complete(id, [{1, "WRONG"}])
  end

  test "complete rejects a missing part number", %{id: id} do
    MP.register_part(id, 1, "e1", 1, "/tmp/p1")
    assert {:error, :invalid_part} == MP.complete(id, [{9, "e9"}])
  end

  test "abort stops the session", %{id: id} do
    assert is_pid(GenServer.whereis(MP.via(id)))
    :ok = MP.abort(id)
    assert GenServer.whereis(MP.via(id)) == nil
  end
end
