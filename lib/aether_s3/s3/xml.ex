defmodule AetherS3.S3.XML do
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  def error(code, message, resource) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>#{code}</Code><Message>#{escape(message)}</Message><Resource>#{escape(resource)}</Resource></Error>
    """
  end

  @ns "http://s3.amazonaws.com/doc/2006-03-01/"

  @doc "Render a ListObjectsV2 page (KeyCount + continuation-token pagination)."
  def list_objects_v2(bucket, r) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="#{@ns}"><Name>#{escape(bucket)}</Name><Prefix>#{escape(r.prefix)}</Prefix><KeyCount>#{r.key_count}</KeyCount><MaxKeys>#{r.max_keys}</MaxKeys>#{opt("Delimiter", r.delimiter)}<IsTruncated>#{r.truncated}</IsTruncated>#{opt("StartAfter", r.start_after)}#{opt("NextContinuationToken", r.next_token && AetherS3.S3.ListObjects.encode_token(r.next_token))}#{contents(r.keys)}#{common_prefixes(r.common_prefixes)}</ListBucketResult>
    """
  end

  @doc "Render a ListObjects (v1) page (marker/NextMarker pagination)."
  def list_objects_v1(bucket, r) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="#{@ns}"><Name>#{escape(bucket)}</Name><Prefix>#{escape(r.prefix)}</Prefix><Marker>#{escape(r.start_after || "")}</Marker><MaxKeys>#{r.max_keys}</MaxKeys>#{opt("Delimiter", r.delimiter)}<IsTruncated>#{r.truncated}</IsTruncated>#{opt("NextMarker", r.next_token)}#{contents(r.keys)}#{common_prefixes(r.common_prefixes)}</ListBucketResult>
    """
  end

  defp contents(keys) do
    Enum.map_join(keys, fn {key, meta} ->
      "<Contents><Key>#{escape(key)}</Key><LastModified>#{DateTime.to_iso8601(meta.last_modified)}</LastModified><Size>#{meta.size}</Size><ETag>\"#{meta.etag}\"</ETag></Contents>"
    end)
  end

  defp common_prefixes(prefixes) do
    Enum.map_join(prefixes, fn p ->
      "<CommonPrefixes><Prefix>#{escape(p)}</Prefix></CommonPrefixes>"
    end)
  end

  # An optional element: emitted only when the value is present (non-nil, non-empty).
  defp opt(_tag, nil), do: ""
  defp opt(_tag, ""), do: ""
  defp opt(tag, value), do: "<#{tag}>#{escape(to_string(value))}</#{tag}>"

  def initiate_multipart(bucket, key, upload_id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult><Bucket>#{escape(bucket)}</Bucket><Key>#{escape(key)}</Key><UploadId>#{upload_id}</UploadId></InitiateMultipartUploadResult>
    """
  end

  def complete_multipart(bucket, key, etag) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUploadResult><Location>/#{escape(bucket)}/#{escape(key)}</Location><Bucket>#{escape(bucket)}</Bucket><Key>#{escape(key)}</Key><ETag>"#{etag}"</ETag></CompleteMultipartUploadResult>
    """
  end

  def parse_complete(xml) do
    {:ok, {"CompleteMultipartUpload", _attrs, children}} = Saxy.SimpleForm.parse_string(xml)

    for {"Part", _attrs, part_children} <- children do
      pn = field(part_children, "PartNumber") |> String.to_integer()
      etag = field(part_children, "ETag") |> String.trim("\"")
      {pn, etag}
    end
  end

  defp field(children, tag) do
    Enum.find_value(children, fn
      {^tag, _attrs, [text]} -> text
      _ -> nil
    end)
  end
end
