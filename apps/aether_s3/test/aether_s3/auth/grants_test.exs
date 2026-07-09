defmodule AetherS3.Auth.GrantsTest do
  use ExUnit.Case, async: true

  alias AetherS3.Auth.Grants

  test "covers?/2 permission coverage" do
    assert Grants.covers?(:full, :list)
    assert Grants.covers?(:full, :get)
    assert Grants.covers?(:full, :write)
    assert Grants.covers?(:list, :list)
    assert Grants.covers?(:get, :get)
    assert Grants.covers?(:write, :write)
    refute Grants.covers?(:get, :list)
    refute Grants.covers?(:list, :get)
    refute Grants.covers?(:get, :write)
    # legacy :read still covers both list and get
    assert Grants.covers?(:read, :list)
    assert Grants.covers?(:read, :get)
    refute Grants.covers?(:read, :write)
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

  test "scope_matches?/2 matches the scope to the correct keys" do
    assert Grants.scope_matches?("photos/cat.jpg", "photos/cat.jpg")
    refute Grants.scope_matches?("photos/cat.jpg", "photos/cat.jpg2")
    assert Grants.scope_matches?("photos/*", "photos/a.jpg")
    refute Grants.scope_matches?("photos/*", "docs/a.pdf")
    assert Grants.scope_matches?("*", "anything")
  end

  test "allows_for_key?/4: bucket-wide grants apply to every key" do
    record = %{grants: [%{grantee: :everyone, permission: :get}], scoped_grants: []}
    anon = Grants.principals(:anonymous, [])
    assert Grants.allows_for_key?(record, anon, "any/key", :get)
    refute Grants.allows_for_key?(record, anon, "any/key", :write)
  end

  test "allows_for_key?/4: a scoped grant applies only to matching keys" do
    record = %{
      grants: [],
      scoped_grants: [
        %{scope: "photos/cat.jpg", grants: [%{grantee: {:user, "bob"}, permission: :get}]},
        %{scope: "shared/*", grants: [%{grantee: {:user, "bob"}, permission: :write}]}
      ]
    }

    bob = Grants.principals(%{user: "bob"}, [])

    # exact-object grant: only that object
    assert Grants.allows_for_key?(record, bob, "photos/cat.jpg", :get)
    refute Grants.allows_for_key?(record, bob, "photos/dog.jpg", :get)

    # prefix grant: the whole subtree, but only the granted permission
    assert Grants.allows_for_key?(record, bob, "shared/a/b.txt", :write)
    refute Grants.allows_for_key?(record, bob, "shared/a/b.txt", :get)
    refute Grants.allows_for_key?(record, bob, "private/x", :write)
  end

  test "allows_for_key?/4: tolerates a record with no scoped_grants field" do
    record = %{grants: [%{grantee: :everyone, permission: :get}]}
    anon = Grants.principals(:anonymous, [])
    assert Grants.allows_for_key?(record, anon, "k", :get)
  end

  test "allows?/3 matches a grant to a principal + covers the permission" do
    grants = [
      %{grantee: {:user, "bob"}, permission: :get},
      %{grantee: {:group, "eng"}, permission: :full}
    ]

    bob = Grants.principals(%{user: "bob"}, [])
    assert Grants.allows?(grants, bob, :get)
    refute Grants.allows?(grants, bob, :write)
    refute Grants.allows?(grants, bob, :list)

    eng = Grants.principals(%{user: "carol"}, ["eng"])
    assert Grants.allows?(grants, eng, :get)
    assert Grants.allows?(grants, eng, :write)
    assert Grants.allows?(grants, eng, :list)

    stranger = Grants.principals(%{user: "dave"}, [])
    refute Grants.allows?(grants, stranger, :get)
  end

  test "of/1 reads grants, or translates a legacy canned acl" do
    assert Grants.of(%{grants: [%{grantee: :everyone, permission: :read}]}) ==
             [%{grantee: :everyone, permission: :read}]

    assert Grants.of(%{acl: "public-read"}) == [%{grantee: :everyone, permission: :get}]

    assert Grants.of(%{acl: "public-read-write"}) == [
             %{grantee: :everyone, permission: :get},
             %{grantee: :everyone, permission: :write}
           ]

    assert Grants.of(%{acl: "private"}) == []
    assert Grants.of(%{}) == []
  end
end
