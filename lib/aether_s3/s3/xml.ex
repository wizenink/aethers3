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

  def list_bucket(bucket, objects) do
    contents =
      Enum.map_join(objects, fn {key, meta} ->
        "<Contents><Key>#{escape(key)}</Key><LastModified>#{DateTime.to_iso8601(meta.last_modified)}</LastModified><Size>#{meta.size}</Size><ETag>\"#{meta.etag}\"</ETag></Contents>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><Name>#{escape(bucket)}</Name>#{contents}</ListBucketResult>
    """
  end

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
