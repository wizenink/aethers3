defmodule AetherS3.Router do
  use Plug.Router
  import Plug.Conn
  alias AetherS3.Storage.BlobStore
  alias AetherS3.Storage.Streamer
  alias AetherS3.S3.XML
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.ControlPlane.Store, as: ControlPlane
  alias AetherS3.Storage.MultipartSession
  alias AetherS3.Replication.Coordinator

  plug(AetherS3.Plug.SigV4)
  plug(:match)
  plug(:dispatch)

  put "/:bucket" do
    bucket = conn.params["bucket"]
    :ok = ControlPlane.create_bucket(bucket)
    send_resp(conn, 200, "")
  end

  get "/:bucket" do
    bucket = conn.params["bucket"]
    objects = ObjectMeta.list(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, XML.list_bucket(bucket, objects))
  end

  head "/:bucket" do
    bucket = conn.params["bucket"]

    if ControlPlane.bucket_exists?(bucket) do
      send_resp(conn, 200, "")
    else
      send_resp(conn, 404, "")
    end
  end

  delete "/:bucket" do
    bucket = conn.params["bucket"]

    case ControlPlane.delete_bucket(bucket) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_empty} -> send_resp(conn, 409, "BucketNotEmpty\n")
    end
  end

  get "/:bucket/*key" do
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")
    path = BlobStore.path(bucket, key)

    case ObjectMeta.get(bucket, key) do
      {:ok, meta} ->
        range = conn |> get_req_header("range") |> List.first()

        conn
        |> put_resp_header("content-type", meta.content_type)
        |> put_resp_header("last-modified", http_date(meta.last_modified))
        |> Streamer.egress(path, range: range)

      :not_found ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(
          404,
          XML.error("NoSuchKey", "The specified key does not exist.", conn.request_path)
        )
    end
  end

  post "/:bucket/*key" do
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")
    conn = fetch_query_params(conn)

    cond do
      Map.has_key?(conn.query_params, "uploads") ->
        upload_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            AetherS3.UploadSupervisor,
            {MultipartSession, %{upload_id: upload_id, bucket: bucket, key: key}}
          )

        send_xml(conn, 200, XML.initiate_multipart(bucket, key, upload_id))

      Map.has_key?(conn.query_params, "uploadId") ->
        upload_id = conn.query_params["uploadId"]
        {:ok, body, conn} = read_body(conn, length: 2_000_000)
        requested = XML.parse_complete(body)

        case MultipartSession.complete(upload_id, requested) do
          {:ok, paths} ->
            dest = BlobStore.path(bucket, key)
            {:ok, %{size: size, etag: etag}} = Streamer.assemble(paths, dest)

            :ok =
              ObjectMeta.put(bucket, key, %{
                size: size,
                etag: etag,
                content_type: "application/octet-stream",
                last_modified: DateTime.utc_now()
              })

            # stops the session; its terminate/2 deletes the now-redundant temp parts
            MultipartSession.abort(upload_id)
            send_xml(conn, 200, XML.complete_multipart(bucket, key, etag))

          {:error, :invalid_part} ->
            send_xml(
              conn,
              400,
              XML.error("InvalidPart", "One or more parts were invalid.", conn.request_path)
            )
        end

      true ->
        send_resp(conn, 400, "")
    end
  end

  head "/:bucket/*key" do
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")

    case Coordinator.locate(bucket, key) do
      {:ok, meta, _node} ->
        conn
        |> put_resp_header("etag", ~s("#{meta.etag}"))
        |> put_resp_header("content-length", Integer.to_string(meta.size))
        |> put_resp_header("content-type", meta.content_type)
        |> put_resp_header("last-modified", http_date(meta.last_modified))
        |> send_resp(200, "")

      :not_found ->
        send_resp(conn, 404, "")
    end
  end

  put "/:bucket/*key" do
    conn = fetch_query_params(conn)
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")

    case conn.query_params do
      %{"partNumber" => pn, "uploadId" => upload_id} ->
        part_number = String.to_integer(pn)
        path = BlobStore.multipart_part_path(upload_id, part_number)

        case Streamer.ingest(conn, path) do
          {:ok, %{size: size, etag: etag}} ->
            :ok = MultipartSession.register_part(upload_id, part_number, etag, size, path)

            conn
            |> put_resp_header("etag", ~s("#{etag}"))
            |> send_resp(200, "")

          {:error, _reason} ->
            send_xml(
              conn,
              500,
              XML.error("InternalError", "Part upload failed.", conn.request_path)
            )
        end

      _ ->
        content_type =
          conn |> get_req_header("content-type") |> List.first() || "application/octet-stream"

        if ControlPlane.bucket_exists?(bucket) do
          case Coordinator.put(conn, bucket, key, content_type) do
            {:ok, etag} ->
              conn
              |> put_resp_header("etag", ~s("#{etag}"))
              |> send_resp(200, "")

            {:error, _reason} ->
              send_xml(
                conn,
                500,
                XML.error("InternalError", "Upload could not be completed.", conn.request_path)
              )
          end
        else
          send_xml(
            conn,
            404,
            XML.error("NoSuchBucket", "The specified bucket does not exist.", conn.request_path)
          )
        end
    end
  end

  delete "/:bucket/*key" do
    conn = fetch_query_params(conn)
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")

    case conn.query_params do
      %{"uploadId" => upload_id} ->
        # abort: stop the session if it's still alive (terminate/2 cleans temp parts)
        case GenServer.whereis(MultipartSession.via(upload_id)) do
          nil -> :ok
          _pid -> MultipartSession.abort(upload_id)
        end

        send_resp(conn, 204, "")

      _ ->
        path = BlobStore.path(bucket, key)
        :ok = ObjectMeta.delete(bucket, key)
        File.rm(path)
        send_resp(conn, 204, "")
    end
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  defp send_xml(conn, status, body) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, body)
  end

  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
