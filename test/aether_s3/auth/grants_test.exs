defmodule AetherS3.Auth.GrantsTest do
  use ExUnit.Case, async: true

  alias AetherS3.Auth.Grants

  test "covers?/2 permission coverage" do
    assert Grants.covers?(:full, :read)
    assert Grants.covers?(:full, :write)
    assert Grants.covers?(:read, :read)
    assert Grants.covers?(:write, :write)
    refute Grants.covers?(:read, :write)
    refute Grants.covers?(:write, :read)
  end

  test "principals/2: a user embodies itself, its groups, and everyone" do
    p = Grants.principals(%{user: "bob"}, ["eng", "ops"])
    assert MapSet.member?(p, {:user, "bob"})
    assert MapSet.member?(p, {:group, "eng"})
    assert MapSet.member?(p, {:group, "ops"})
    assert MapSet.member?(p, :everyone)
  end

  test "principals/2: anonymous embodies only everyone" do
    p = Grants.principals(:anonymous, [])
    assert MapSet.equal?(p, MapSet.new([:everyone]))
  end

  test "allows?/3 matches a grant to a principal + covers the permission" do
    grants = [
      %{grantee: {:user, "bob"}, permission: :read},
      %{grantee: {:group, "eng"}, permission: :full}
    ]

    bob = Grants.principals(%{user: "bob"}, [])
    assert Grants.allows?(grants, bob, :read)
    refute Grants.allows?(grants, bob, :write)

    eng = Grants.principals(%{user: "carol"}, ["eng"])
    assert Grants.allows?(grants, eng, :read)
    assert Grants.allows?(grants, eng, :write)

    stranger = Grants.principals(%{user: "dave"}, [])
    refute Grants.allows?(grants, stranger, :read)
  end

  test "of/1 reads grants, or translates a legacy canned acl" do
    assert Grants.of(%{grants: [%{grantee: :everyone, permission: :read}]}) ==
             [%{grantee: :everyone, permission: :read}]

    assert Grants.of(%{acl: "public-read"}) == [%{grantee: :everyone, permission: :read}]
    assert Grants.of(%{acl: "public-read-write"}) == [%{grantee: :everyone, permission: :full}]
    assert Grants.of(%{acl: "private"}) == []
    assert Grants.of(%{}) == []
  end
end
