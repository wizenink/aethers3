defmodule AetherS3.Router do
  use Plug.Router
  import Plug.Conn
  alias AetherS3.Storage.BlobStore
  alias AetherS3.Storage.Streamer
  alias AetherS3.S3.XML
  alias AetherS3.S3.Acl
  alias AetherS3.Auth.Grants
  alias AetherS3.ControlPlane.Store, as: ControlPlane
  alias AetherS3.Storage.Multipart
  alias AetherS3.Replication.Coordinator

  plug(AetherS3.Plug.ReservedBucket)
  plug(AetherS3.Plug.SigV4)
  plug(AetherS3.Plug.Authorize)
  plug(:match)
  plug(:dispatch)

  put "/:bucket" do
    conn = fetch_query_params(conn)
    bucket = conn.params["bucket"]

    if Map.has_key?(conn.query_params, "acl") do
      # Set grants (owner/admin only — enforced by the Authorize plug, which treats
      # PUT on an existing bucket as owner-only). A `prefix` param scopes the grants
      # to a key prefix; otherwise they apply bucket-wide.
      result =
        case conn.query_params["prefix"] do
          nil -> ControlPlane.set_bucket_grants(bucket, acl_grants(conn))
          raw -> ControlPlane.set_scoped_grants(bucket, normalize_prefix(raw), acl_grants(conn))
        end

      respond_set_grants(conn, result)
    else
      case ControlPlane.create_bucket(bucket, owner_of(conn.assigns[:identity])) do
        :ok ->
          # Honor any ACL grant supplied at create time (x-amz-acl / x-amz-grant-*).
          case acl_grants(conn) do
            [] -> :ok
            grants -> ControlPlane.set_bucket_grants(bucket, grants)
          end

          send_resp(conn, 200, "")

        {:error, :unavailable} ->
          unavailable(conn)
      end
    end
  end

  get "/:bucket" do
    conn = fetch_query_params(conn)
    bucket = conn.params["bucket"]

    cond do
      Map.has_key?(conn.query_params, "acl") ->
        # Read grants back: a `prefix` param reads that scoped ACL, else bucket-wide.
        scope = conn.query_params["prefix"] && normalize_prefix(conn.query_params["prefix"])
        acl_xml(conn, bucket, scope)

      true ->
        objects = Coordinator.list(bucket)

        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, XML.list_bucket(bucket, objects))
    end
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
      {:error, :unavailable} -> unavailable(conn)
    end
  end

  get "/:bucket/*key" do
    conn = fetch_query_params(conn)
    bucket = conn.params["bucket"]
    key = Enum.join(conn.params["key"], "/")

    if Map.has_key?(conn.query_params, "acl") do
      # Read this object's ACL (scope = exact key).
      acl_xml(conn, bucket, key)
    else
      get_object(conn, bucket, key)
    end
  end

  defp get_object(conn, bucket, key) do
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

    cond do
      Map.has_key?(conn.query_params, "acl") ->
        # Per-object ACL: scope the grants to this exact key (owner/admin only, via
        # the Authorize plug). x-amz-acl: private clears it (empty grants).
        respond_set_grants(conn, ControlPlane.set_scoped_grants(bucket, key, acl_grants(conn)))

      true ->
        put_object(conn, bucket, key)
    end
  end

  defp put_object(conn, bucket, key) do
    case conn.query_params do
      %{"partNumber" => pn, "uploadId" => upload_id} ->
        part_number = String.to_integer(pn)

        # A part is just a normal replicated object under the reserved bucket;
        # Complete will discover it by prefix scan and reference it in the manifest.
        part_key = Multipart.part_key(upload_id, part_number)

        case Coordinator.put(conn, Multipart.bucket(), part_key, "application/octet-stream") do
          {:ok, etag, conn} ->
            conn
            |> put_resp_header("etag", ~s("#{etag}"))
            |> send_resp(200, "")

          {:error, :insufficient_replicas, conn} ->
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
            {:ok, etag, conn} ->
              conn
              |> put_resp_header("etag", ~s("#{etag}"))
              |> send_resp(200, "")

            {:error, :insufficient_replicas, conn} ->
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
        :telemetry.execute([:aether, :multipart, :aborted], %{count: 1}, %{})
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

  # The owning user for a newly-created bucket: an authenticated identity's user,
  # or nil when auth is disabled/anonymous (authorization gates who reaches here).
  defp owner_of(%{user: user}), do: user
  defp owner_of(_), do: nil

  # Grants requested via ACL headers (x-amz-acl canned, or x-amz-grant-*).
  defp acl_grants(conn), do: Acl.grants(&get_req_header(conn, &1))

  # Common response for a set-grants call (bucket-wide or scoped).
  defp respond_set_grants(conn, :ok), do: send_resp(conn, 200, "")

  defp respond_set_grants(conn, {:error, :no_such_bucket}) do
    send_xml(
      conn,
      404,
      XML.error("NoSuchBucket", "The specified bucket does not exist.", conn.request_path)
    )
  end

  defp respond_set_grants(conn, {:error, :unavailable}), do: unavailable(conn)

  # A `prefix` ACL param carries prefix semantics; ensure the stored scope reflects
  # that (a trailing `*`) so Grants.scope_matches? treats it as a prefix, not exact.
  defp normalize_prefix(prefix) do
    if String.ends_with?(prefix, "*"), do: prefix, else: prefix <> "*"
  end

  # Serialize a bucket's grants (bucket-wide when scope is nil, else the entry for
  # that scope) as an S3 AccessControlPolicy document.
  defp acl_xml(conn, bucket, scope) do
    case ControlPlane.get_bucket(bucket) do
      nil ->
        send_xml(
          conn,
          404,
          XML.error("NoSuchBucket", "The specified bucket does not exist.", conn.request_path)
        )

      record ->
        grants =
          case scope do
            nil -> Grants.of(record)
            s -> grants_for_scope(record, s)
          end

        send_xml(conn, 200, Acl.to_xml(record.owner, grants))
    end
  end

  defp grants_for_scope(record, scope) do
    case Enum.find(Grants.scoped(record), &(&1.scope == scope)) do
      %{grants: grants} -> grants
      nil -> []
    end
  end

  # The control plane couldn't commit (no reachable Raft leader) — fail fast.
  defp unavailable(conn) do
    send_xml(
      conn,
      503,
      XML.error("ServiceUnavailable", "The control plane is unavailable.", conn.request_path)
    )
  end
end
