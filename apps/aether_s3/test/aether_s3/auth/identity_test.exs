defmodule AetherS3.Auth.IdentityTest do
  # NOT async: mints keys into the shared Khepri store and toggles :master_key.
  use ExUnit.Case

  alias AetherS3.Auth.Identity
  alias AetherS3.Auth.SecretBox
  alias AetherS3.ControlPlane.Store

  @master "test-master-passphrase"

  setup do
    prev = Application.get_env(:aether_s3, :master_key)
    Application.put_env(:aether_s3, :master_key, @master)
    on_exit(fn -> Application.put_env(:aether_s3, :master_key, prev) end)
    :ok
  end

  test "resolves the config-seeded root (plaintext secret, admin)" do
    assert {:ok, %{user: "root", admin: true, secret: "devsecret"}} =
             Identity.resolve("AKIAEXAMPLE")

    assert Identity.admin?("AKIAEXAMPLE")
  end

  test "resolves a dynamic key, decrypting the secret" do
    key = SecretBox.derive_key(@master)
    Store.put_user("alice", false)
    Store.put_key("AKIA_ALICE", "alice", SecretBox.encrypt("alice-secret", key))

    assert {:ok, %{user: "alice", admin: false, secret: "alice-secret"}} =
             Identity.resolve("AKIA_ALICE")

    refute Identity.admin?("AKIA_ALICE")
  end

  test "a dynamic key of an admin user resolves as admin" do
    key = SecretBox.derive_key(@master)
    Store.put_user("boss", true)
    Store.put_key("AKIA_BOSS", "boss", SecretBox.encrypt("boss-secret", key))

    assert {:ok, %{admin: true}} = Identity.resolve("AKIA_BOSS")
  end

  test "an unknown access key is :error" do
    assert Identity.resolve("AKIA_NOPE-#{System.unique_integer()}") == :error
  end

  test "a key whose secret won't decrypt fails closed (:error)" do
    wrong = SecretBox.derive_key("some-other-key")
    Store.put_user("mallory", false)
    Store.put_key("AKIA_MAL", "mallory", SecretBox.encrypt("x", wrong))

    assert Identity.resolve("AKIA_MAL") == :error
  end
end
