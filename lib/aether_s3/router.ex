defmodule AetherS3.Router do
  use Plug.Router
  import Plug.Conn
  alias AetherS3.Storage.BlobStore
  alias AetherS3.Storage.Streamer
  alias AetherS3.S3.XML
  alias AetherS3.ControlPlane.Store, as: ControlPlane
  alias AetherS3.Storage.Multipart
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
    objects = Coordinator.list(bucket)

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
    range = conn |> get_req_header("range") |> List.first()

    case Coordinator.locate_repair(bucket, key) do
      {:ok, %{parts: parts} = meta, _node} ->
        conn =
          conn
          |> put_resp_header("content-type", meta.content_type)
          |> put_resp_header("last-modified", http_date(meta.last_modified))

        case Streamer.egress_manifest(
               conn,
               parts,
               &Coordinator.locate_repair(Multipart.bucket(), &1.key),
               range: range
             ) do
          {:error, :missing_part} -> send_resp(conn, 500, "")
          conn -> conn
        end

      {:ok, meta, node} ->
        conn =
          conn
          |> put_resp_header("content-type", meta.content_type)
          |> put_resp_header("last-modified", http_date(meta.last_modified))

        if node == Node.self() do
          Streamer.egress(conn, BlobStore.path(bucket, key), range: range)
        else
          Streamer.egress_remote(conn, node, bucket, key, meta.size, range: range)
        end

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
        # Stateless: no session to start — the upload id just namespaces the part
        # objects we'll store under the reserved bucket.
        upload_id = Multipart.new_upload_id()

        content_type =
          conn |> get_req_header("content-type") |> List.first() || "application/octet-stream"

        Coordinator.put_upload_meta(upload_id, content_type)
        send_xml(conn, 200, XML.initiate_multipart(bucket, key, upload_id))

      Map.has_key?(conn.query_params, "uploadId") ->
        upload_id = conn.query_params["uploadId"]
        {:ok, body, conn} = read_body(conn, length: 2_000_000)
        requested = XML.parse_complete(body)

        case Coordinator.complete_multipart(
               bucket,
               key,
               upload_id,
               requested
             ) do
          {:ok, etag} ->
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

    case Coordinator.locate_repair(bucket, key) do
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

        # A part is just a normal replicated object under the reserved bucket;
        # Complete will discover it by prefix scan and reference it in the manifest.
        part_key = Multipart.part_key(upload_id, part_number)

        case Coordinator.put(conn, Multipart.bucket(), part_key, "application/octet-stream") do
          {:ok, etag} ->
            conn
            |> put_resp_header("etag", ~s("#{etag}"))
            |> send_resp(200, "")

          {:error, :insufficient_replicas} ->
            send_xml(
              conn,
              503,
              XML.error(
                "ServiceUnavailable",
                "Not enough replicas to store part.",
                conn.request_path
              )
            )

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

            {:error, :insufficient_replicas} ->
              send_xml(
                conn,
                503,
                XML.error(
                  "ServiceUnavailable",
                  "Not enough replicas to store object.",
                  conn.request_path
                )
              )

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
        # abort: delete every part object stored under this upload
        Coordinator.abort_multipart(upload_id)
        send_resp(conn, 204, "")

      _ ->
        :ok = Coordinator.delete(bucket, key)
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
