defmodule AetherS3.Storage.MultipartTest do
  use ExUnit.Case, async: true

  alias AetherS3.Storage.Multipart

  test "part_key namespaces parts under the upload id" do
    assert Multipart.part_key("U1", 3) == "U1/3"
  end

  test "new_upload_id is opaque and unique" do
    refute Multipart.new_upload_id() == Multipart.new_upload_id()
  end

  test "multipart_etag matches the S3 scheme (md5 of concatenated binary part md5s + -N)" do
    # md5("foo") and md5("bar"); expected value verified independently against the
    # AWS S3 multipart ETag algorithm.
    parts = ["acbd18db4cc2f85cedef654fccc4a4d8", "37b51d194a7513e45b56f6524f2d51f2"]
    assert Multipart.multipart_etag(parts) == "0105fcbc9eea8193de8e1834677b6c6b-2"
  end

  test "multipart_etag suffix counts the parts" do
    one = ["acbd18db4cc2f85cedef654fccc4a4d8"]
    assert Multipart.multipart_etag(one) =~ ~r/^[0-9a-f]{32}-1$/
  end
end
