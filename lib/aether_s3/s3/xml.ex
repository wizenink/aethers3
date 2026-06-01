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
end
