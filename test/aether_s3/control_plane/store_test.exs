defmodule AetherS3.ControlPlane.StoreTest do
  # NOT async: Khepri is a single shared store, so these must not run
  # concurrently with other tests that touch it.
  use ExUnit.Case

  alias AetherS3.ControlPlane.Store

  test "user round-trips with its admin flag" do
    :ok = Store.put_user("alice", true)
    assert %{admin: true} = Store.get_user("alice")

    :ok = Store.put_user("bob", false)
    assert %{admin: false} = Store.get_user("bob")
  end

  test "key round-trips and points back at its user" do
    :ok = Store.put_key("AKIA_T1", "alice", "enc-blob")
    assert %{user: "alice", secret_enc: "enc-blob"} = Store.get_key("AKIA_T1")
  end

  test "a user can own multiple keys" do
    :ok = Store.put_key("AKIA_A", "carol", "enc-a")
    :ok = Store.put_key("AKIA_B", "carol", "enc-b")
    assert %{user: "carol"} = Store.get_key("AKIA_A")
    assert %{user: "carol"} = Store.get_key("AKIA_B")
  end

  test "missing user/key reads as nil" do
    assert Store.get_user("nobody-#{System.unique_integer()}") == nil
    assert Store.get_key("nope-#{System.unique_integer()}") == nil
  end

  test "delete_key removes the key" do
    :ok = Store.put_key("AKIA_T2", "alice", "x")
    assert %{user: "alice"} = Store.get_key("AKIA_T2")

    :ok = Store.delete_key("AKIA_T2")
    assert Store.get_key("AKIA_T2") == nil
  end

  test "list_users returns every user with its name" do
    n = System.unique_integer([:positive])
    Store.put_user("lu-a-#{n}", false)
    Store.put_user("lu-b-#{n}", true)

    users = Store.list_users()
    names = Enum.map(users, & &1.name)
    assert "lu-a-#{n}" in names
    assert "lu-b-#{n}" in names
    assert Enum.find(users, &(&1.name == "lu-b-#{n}")).admin == true
  end

  test "keys_of returns only the given user's access keys" do
    n = System.unique_integer([:positive])
    Store.put_key("AKIA_KO1_#{n}", "ko-owner-#{n}", "x")
    Store.put_key("AKIA_KO2_#{n}", "ko-owner-#{n}", "y")
    Store.put_key("AKIA_OTHER_#{n}", "someone-else-#{n}", "z")

    keys = Store.keys_of("ko-owner-#{n}")
    assert "AKIA_KO1_#{n}" in keys
    assert "AKIA_KO2_#{n}" in keys
    refute "AKIA_OTHER_#{n}" in keys
  end

  test "delete_user removes the user and cascades its keys" do
    n = System.unique_integer([:positive])
    Store.put_user("du-#{n}", false)
    Store.put_key("AKIA_DU1_#{n}", "du-#{n}", "x")
    Store.put_key("AKIA_DU2_#{n}", "du-#{n}", "y")

    :ok = Store.delete_user("du-#{n}")
    assert Store.get_user("du-#{n}") == nil
    assert Store.get_key("AKIA_DU1_#{n}") == nil
    assert Store.get_key("AKIA_DU2_#{n}") == nil
  end
end
