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

  test "list_bucket renders each object's key, size and etag" do
    objects = [
      {"cat.jpg", %{size: 10, etag: "abc", last_modified: ~U[2026-01-01 00:00:00Z]}},
      {"a&b.txt", %{size: 7, etag: "def", last_modified: ~U[2026-01-02 00:00:00Z]}}
    ]

    xml = XML.list_bucket("photos", objects)
    assert xml =~ "<Name>photos</Name>"
    assert xml =~ "<Key>cat.jpg</Key>"
    assert xml =~ "<Size>10</Size>"
    assert xml =~ ~s(<ETag>"abc"</ETag>)
    assert xml =~ "<Key>a&amp;b.txt</Key>"
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
