defmodule AetherS3.Router do
  use Plug.Router
  import Plug.Conn
  alias AetherS3.Storage.BlobStore
  alias AetherS3.Storage.Streamer
  alias AetherS3.S3.XML
  alias AetherS3.ObjectMeta.Store, as: ObjectMeta
  alias AetherS3.ControlPlane.Store, as: ControlPlane

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
        conn
        |> put_resp_header("content-type", meta.content_type)
        |> put_resp_header("last-modified", http_date(meta.last_modified))
        |> Streamer.egress(path)

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
    send_resp(conn, 200, "POST bucket=#{bucket} key=#{key}")
  end

  head "/:bucket/*key" do
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")

    case ObjectMeta.get(bucket, key) do
      {:ok, meta} ->
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
    content_type =
      conn |> get_req_header("content-type") |> List.first() || "application/octet-stream"

    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")
    path = BlobStore.path(bucket, key)

    if ControlPlane.bucket_exists?(bucket) do
      case Streamer.ingest(conn, path) do
        {:ok, %{size: size, etag: etag}} ->
          :ok =
            ObjectMeta.put(bucket, key, %{
              size: size,
              etag: etag,
              content_type: content_type,
              last_modified: DateTime.utc_now()
            })

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

  delete "/:bucket/*key" do
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")
    path = BlobStore.path(bucket, key)
    :ok = ObjectMeta.delete(bucket, key)
    File.rm(path)
    send_resp(conn, 204, "")
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
