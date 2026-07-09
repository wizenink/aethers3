defmodule AetherS3.S3.XMLTest do
  use ExUnit.Case, async: true

  alias AetherS3.S3.XML

  test "escape replaces &, <, > (ampersand first, no double-escaping)" do
    assert XML.escape("a<b&c>d") == "a&lt;b&amp;c&gt;d"
  end

  test "error document carries the code and an escaped resource" do
    xml = XML.error("NoSuchKey", "missing", "/a&b")
    assert xml =~ "<Code>NoSuchKey</Code>"
    assert xml =~ "<Resource>/a&amp;b</Resource>"
  end

  test "list_objects_v2 renders each object's key/size/etag plus paging metadata" do
    result = %{
      keys: [
        {"cat.jpg", %{size: 10, etag: "abc", last_modified: ~U[2026-01-01 00:00:00Z]}},
        {"a&b.txt", %{size: 7, etag: "def", last_modified: ~U[2026-01-02 00:00:00Z]}}
      ],
      common_prefixes: ["sub/"],
      next_token: "cat.jpg",
      truncated: true,
      key_count: 3,
      max_keys: 2,
      prefix: "",
      delimiter: "/",
      start_after: nil
    }

    xml = XML.list_objects_v2("photos", result)
    assert xml =~ "<Name>photos</Name>"
    assert xml =~ "<Key>cat.jpg</Key>"
    assert xml =~ "<Size>10</Size>"
    assert xml =~ ~s(<ETag>"abc"</ETag>)
    assert xml =~ "<Key>a&amp;b.txt</Key>"
    assert xml =~ "<KeyCount>3</KeyCount>"
    assert xml =~ "<IsTruncated>true</IsTruncated>"
    assert xml =~ "<CommonPrefixes><Prefix>sub/</Prefix></CommonPrefixes>"
    # NextContinuationToken is the base64 of the resume key
    assert xml =~ "<NextContinuationToken>#{Base.url_encode64("cat.jpg")}</NextContinuationToken>"
  end

  test "list_objects_v1 uses Marker/NextMarker instead of continuation tokens" do
    result = %{
      keys: [{"k", %{size: 1, etag: "e", last_modified: ~U[2026-01-01 00:00:00Z]}}],
      common_prefixes: [],
      next_token: "k",
      truncated: true,
      key_count: 1,
      max_keys: 1,
      prefix: "p/",
      delimiter: nil,
      start_after: "j"
    }

    xml = XML.list_objects_v1("b", result)
    assert xml =~ "<Marker>j</Marker>"
    assert xml =~ "<NextMarker>k</NextMarker>"
    refute xml =~ "KeyCount"
    refute xml =~ "ContinuationToken"
  end

  test "initiate_multipart includes the upload id" do
    assert XML.initiate_multipart("b", "k", "UID123") =~ "<UploadId>UID123</UploadId>"
  end

  test "parse_complete extracts ordered {part_number, etag} tuples, stripping quotes" do
    xml = """
    <CompleteMultipartUpload>
      <Part><PartNumber>1</PartNumber><ETag>"e1"</ETag></Part>
      <Part><PartNumber>2</PartNumber><ETag>"e2"</ETag></Part>
    </CompleteMultipartUpload>
    """

    assert XML.parse_complete(xml) == [{1, "e1"}, {2, "e2"}]
  end
end
