defmodule AetherS3.Router do
  use Plug.Router
  import Plug.Conn
  alias AetherS3.Storage.BlobStore
  alias AetherS3.Storage.Streamer
  alias AetherS3.S3.XML
  alias AetherS3.S3.Acl
  alias AetherS3.S3.ListObjects
  alias AetherS3.S3.Conditional
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
        render_list(conn, bucket)
    end
  end

  defp render_list(conn, bucket) do
    qp = conn.query_params
    result = ListObjects.paginate(Coordinator.list(bucket), list_opts(qp))

    body =
      if qp["list-type"] == "2",
        do: XML.list_objects_v2(bucket, result),
        else: XML.list_objects_v1(bucket, result)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # Translate S3 LIST query params into ListObjects options. v2 resumes from
  # continuation-token (opaque) or start-after; v1 resumes from marker.
  defp list_opts(qp) do
    after_key =
      cond do
        qp["list-type"] == "2" and qp["continuation-token"] ->
          ListObjects.decode_token(qp["continuation-token"])

        qp["list-type"] == "2" ->
          qp["start-after"]

        true ->
          qp["marker"]
      end

    [
      prefix: qp["prefix"] || "",
      delimiter: presence(qp["delimiter"]),
      max_keys: parse_int(qp["max-keys"]),
      after: after_key
    ]
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v), do: v

  defp parse_int(nil), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _rest} -> n
      :error -> nil
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

  # POST /:bucket?delete — DeleteObjects (bulk delete, up to 1000 keys). Used by
  # `aws s3 rm --recursive`, `aws s3 sync --delete`, and warp's cleanup.
  post "/:bucket" do
    conn = fetch_query_params(conn)
    bucket = conn.params["bucket"]

    if Map.has_key?(conn.query_params, "delete") do
      bulk_delete(conn, bucket)
    else
      send_resp(conn, 400, "")
    end
  end

  defp bulk_delete(conn, bucket) do
    if ControlPlane.bucket_exists?(bucket) do
      {:ok, body, conn} = read_body(conn, length: 1_000_000)
      {keys, quiet} = XML.parse_delete(body)

      {deleted, errors} =
        Enum.reduce(keys, {[], []}, fn key, {del, err} ->
          case safe_delete(bucket, key) do
            :ok -> {[key | del], err}
            {:error, code, message} -> {del, [{key, code, message} | err]}
          end
        end)

      # Quiet mode reports only errors; a delete of a missing key is a success (S3
      # delete is idempotent), so keys that were never there still come back Deleted.
      deleted = if quiet, do: [], else: Enum.reverse(deleted)
      send_xml(conn, 200, XML.delete_result(deleted, Enum.reverse(errors)))
    else
      send_xml(
        conn,
        404,
        XML.error("NoSuchBucket", "The specified bucket does not exist.", conn.request_path)
      )
    end
  end

  defp safe_delete(bucket, key) do
    Coordinator.delete(bucket, key)
    :ok
  rescue
    _ -> {:error, "InternalError", "The object could not be deleted."}
  catch
    _, _ -> {:error, "InternalError", "The object could not be deleted."}
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
      {:ok, meta, node} ->
        # Preconditions are evaluated before any bytes move, so a 304/412 costs a
        # metadata lookup rather than a streamed body.
        case Conditional.evaluate_read(conn.req_headers, meta) do
          :ok -> serve_object(conn, bucket, key, meta, node, range)
          :not_modified -> not_modified(conn, meta)
          :precondition_failed -> precondition_failed(conn)
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

  # A completed multipart object is a manifest (meta-only, parts held separately).
  defp serve_object(conn, _bucket, _key, %{parts: parts} = meta, _node, range) do
    conn =
      conn
      |> maybe_put_etag(meta)
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
  end

  defp serve_object(conn, bucket, key, meta, node, range) do
    conn =
      conn
      |> maybe_put_etag(meta)
      |> put_resp_header("content-type", meta.content_type)
      |> put_resp_header("last-modified", http_date(meta.last_modified))

    if node == Node.self() do
      Streamer.egress(
        conn,
        BlobStore.path(bucket, key),
        egress_opts(bucket, key, meta, range)
      )
    else
      Streamer.egress_remote(conn, node, bucket, key, meta.size, range: range)
    end
  end

  # 304 carries the validators (and no body) so the client can refresh its cache
  # entry without a re-fetch.
  defp not_modified(conn, meta) do
    conn
    |> maybe_put_etag(meta)
    |> put_resp_header("last-modified", http_date(meta.last_modified))
    |> send_resp(304, "")
  end

  defp precondition_failed(conn) do
    send_xml(
      conn,
      412,
      XML.error(
        "PreconditionFailed",
        "At least one of the preconditions you specified did not hold.",
        conn.request_path
      )
    )
  end

  defp maybe_put_etag(conn, meta) do
    case Map.get(meta, :etag) do
      nil -> conn
      etag -> put_resp_header(conn, "etag", ~s("#{etag}"))
    end
  end

  # Egress options for a local read. When AETHER_VERIFY_READS is on and this is a
  # full read (no Range), ask the streamer to verify the blob's md5 against the
  # stored etag as it streams, and heal it in the background on a mismatch. Ranged
  # reads can't be checked against the whole-object etag, so they're never verified.
  defp egress_opts(bucket, key, meta, range) do
    if is_nil(range) and verify_reads?() and Map.has_key?(meta, :etag) do
      [range: range, verify_etag: meta.etag, on_corrupt: fn -> heal_async(bucket, key, meta) end]
    else
      [range: range]
    end
  end

  defp verify_reads?, do: Application.get_env(:aether_s3, :verify_reads, false)

  defp heal_async(bucket, key, meta) do
    Task.start(fn -> AetherS3.Storage.Scrubber.scrub_object(bucket, key, meta) end)
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
        # HEAD must not carry a body, so the 412 here is bare rather than the XML
        # error document GET returns.
        case Conditional.evaluate_read(conn.req_headers, meta) do
          :ok ->
            conn
            |> put_resp_header("etag", ~s("#{meta.etag}"))
            |> put_resp_header("content-length", Integer.to_string(meta.size))
            |> put_resp_header("content-type", meta.content_type)
            |> put_resp_header("last-modified", http_date(meta.last_modified))
            |> send_resp(200, "")

          :not_modified ->
            not_modified(conn, meta)

          :precondition_failed ->
            send_resp(conn, 412, "")
        end

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

      match?([_ | _], get_req_header(conn, "x-amz-copy-source")) ->
        # Server-side copy (aws s3 cp/mv): PUT dest + x-amz-copy-source, empty body.
        # Without this the empty body would be stored as a 0-byte object.
        copy_object(conn, bucket, key)

      true ->
        put_object(conn, bucket, key)
    end
  end

  defp put_object(conn, bucket, key) do
    cond do
      not AetherS3.Storage.DiskGuard.writable?() ->
        :telemetry.execute([:aether, :write, :rejected], %{count: 1}, %{reason: "disk_full"})

        send_xml(
          conn,
          507,
          XML.error("InsufficientStorage", "The node is low on disk space.", conn.request_path)
        )

      oversized?(conn) ->
        :telemetry.execute([:aether, :write, :rejected], %{count: 1}, %{reason: "too_large"})

        send_xml(
          conn,
          400,
          XML.error(
            "EntityTooLarge",
            "The object exceeds the configured maximum size.",
            conn.request_path
          )
        )

      true ->
        do_put_object(conn, bucket, key)
    end
  end

  # Whether the request's declared object size exceeds `:max_object_bytes`. Uses
  # the aws-chunked decoded length when present, else Content-Length. A missing
  # declared size can't be checked up front — the disk guard is the backstop.
  defp oversized?(conn) do
    case {Application.get_env(:aether_s3, :max_object_bytes), declared_size(conn)} do
      {max, size} when is_integer(max) and is_integer(size) -> size > max
      _ -> false
    end
  end

  defp declared_size(conn) do
    raw =
      conn |> get_req_header("x-amz-decoded-content-length") |> List.first() ||
        conn |> get_req_header("content-length") |> List.first()

    case raw && Integer.parse(raw) do
      {n, _rest} -> n
      _ -> nil
    end
  end

  defp do_put_object(conn, bucket, key) do
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
          case conditional_write(conn, bucket, key) do
            :ok -> write_object(conn, bucket, key, content_type)
            :precondition_failed -> precondition_failed(conn)
            :not_found -> send_xml(conn, 404, no_such_key(conn))
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

  # Evaluate If-Match / If-None-Match for a PUT. Only reads the current metadata
  # when a precondition is actually present, so the unconditional path (nearly all
  # writes) pays nothing. Uses `locate_repair` rather than `locate` so the check
  # runs against the freshest replica view instead of whichever answers first —
  # this is a precondition, so a stale read is a wrong answer. Still not atomic:
  # see `AetherS3.S3.Conditional`.
  defp conditional_write(conn, bucket, key) do
    if Conditional.write_conditions?(conn.req_headers) do
      current =
        case Coordinator.locate_repair(bucket, key) do
          {:ok, meta, _node} -> meta
          :not_found -> nil
        end

      Conditional.evaluate_write(conn.req_headers, current)
    else
      :ok
    end
  end

  defp no_such_key(conn),
    do: XML.error("NoSuchKey", "The specified key does not exist.", conn.request_path)

  defp write_object(conn, bucket, key, content_type) do
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
  end

  defp copy_object(conn, dst_bucket, dst_key) do
    source = parse_copy_source(conn)

    cond do
      Map.has_key?(conn.query_params, "partNumber") ->
        # UploadPartCopy — not implemented; reject rather than store an empty part.
        send_xml(
          conn,
          501,
          XML.error("NotImplemented", "UploadPartCopy is not supported.", conn.request_path)
        )

      source == :invalid ->
        send_xml(
          conn,
          400,
          XML.error("InvalidArgument", "Malformed x-amz-copy-source header.", conn.request_path)
        )

      # The reserved multipart bucket isn't a client-visible source.
      elem(source, 0) == Multipart.bucket() ->
        send_xml(
          conn,
          404,
          XML.error("NoSuchKey", "The specified copy source does not exist.", conn.request_path)
        )

      not ControlPlane.bucket_exists?(dst_bucket) ->
        send_xml(
          conn,
          404,
          XML.error("NoSuchBucket", "The specified bucket does not exist.", conn.request_path)
        )

      true ->
        {src_bucket, src_key} = source

        case Coordinator.copy(src_bucket, src_key, dst_bucket, dst_key, copy_content_type(conn)) do
          {:ok, %{etag: etag, last_modified: last_modified}} ->
            send_xml(conn, 200, XML.copy_object_result(etag, last_modified))

          {:error, :no_such_key} ->
            send_xml(
              conn,
              404,
              XML.error(
                "NoSuchKey",
                "The specified copy source does not exist.",
                conn.request_path
              )
            )

          {:error, :missing_part} ->
            send_xml(
              conn,
              500,
              XML.error("InternalError", "The copy source is incomplete.", conn.request_path)
            )

          {:error, :insufficient_replicas} ->
            send_xml(
              conn,
              503,
              XML.error(
                "ServiceUnavailable",
                "Not enough replicas to store the copy.",
                conn.request_path
              )
            )

          {:error, _reason} ->
            send_xml(
              conn,
              500,
              XML.error("InternalError", "The copy could not be completed.", conn.request_path)
            )
        end
    end
  end

  # Parse x-amz-copy-source ("/bucket/key" or "bucket/key", URL-encoded, optional
  # ?versionId) into {bucket, key}, or :invalid.
  defp parse_copy_source(conn) do
    conn
    |> get_req_header("x-amz-copy-source")
    |> List.first("")
    |> URI.decode()
    |> String.trim_leading("/")
    |> String.split("?", parts: 2)
    |> List.first()
    |> String.split("/", parts: 2)
    |> case do
      [bucket, key] when bucket != "" and key != "" -> {bucket, key}
      _ -> :invalid
    end
  end

  # metadata-directive: REPLACE takes the request's content-type; COPY (default)
  # keeps the source's (nil -> Coordinator.copy uses the source meta's type).
  defp copy_content_type(conn) do
    case conn |> get_req_header("x-amz-metadata-directive") |> List.first() do
      "REPLACE" ->
        conn |> get_req_header("content-type") |> List.first() || "application/octet-stream"

      _ ->
        nil
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
