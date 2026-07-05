defmodule AetherS3.Auth.SecretBoxTest do
  use ExUnit.Case, async: true

  alias AetherS3.Auth.SecretBox

  @key SecretBox.derive_key("master passphrase")

  test "round-trips plaintext with the same key" do
    blob = SecretBox.encrypt("s3cr3t-key-material", @key)
    assert {:ok, "s3cr3t-key-material"} = SecretBox.decrypt(blob, @key)
  end

  test "a fresh encrypt uses a fresh IV (blobs differ, both decrypt)" do
    a = SecretBox.encrypt("same", @key)
    b = SecretBox.encrypt("same", @key)
    refute a == b
    assert {:ok, "same"} = SecretBox.decrypt(a, @key)
    assert {:ok, "same"} = SecretBox.decrypt(b, @key)
  end

  test "wrong key fails authentication" do
    blob = SecretBox.encrypt("secret", @key)
    other = SecretBox.derive_key("different passphrase")
    assert SecretBox.decrypt(blob, other) == :error
  end

  test "a tampered blob fails authentication" do
    <<first, rest::binary>> = SecretBox.encrypt("secret", @key)
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    assert SecretBox.decrypt(tampered, @key) == :error
  end

  test "a malformed (too short) blob returns :error, not a crash" do
    assert SecretBox.decrypt("too-short", @key) == :error
  end
end
