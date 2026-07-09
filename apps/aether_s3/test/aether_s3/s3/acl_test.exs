defmodule AetherS3.S3.AclTest do
  use ExUnit.Case, async: true

  alias AetherS3.S3.Acl

  defp getter(headers), do: fn name -> Map.get(headers, name, []) end

  test "parses user, group, and everyone grantees" do
    assert Acl.parse_grantees(~s(id="bob", group="eng", everyone)) ==
             [{:user, "bob"}, {:group, "eng"}, :everyone]

    assert Acl.parse_grantees("user=carol") == [{:user, "carol"}]
  end

  test "builds grants from x-amz-grant-* headers" do
    grants =
      Acl.grants(
        getter(%{
          "x-amz-grant-read" => [~s(id="bob", group="eng")],
          "x-amz-grant-full-control" => [~s(id="carol")]
        })
      )

    assert %{grantee: {:user, "bob"}, permission: :read} in grants
    assert %{grantee: {:group, "eng"}, permission: :read} in grants
    assert %{grantee: {:user, "carol"}, permission: :full} in grants
  end

  test "a canned x-amz-acl wins over explicit grant headers" do
    grants =
      Acl.grants(getter(%{"x-amz-acl" => ["public-read"], "x-amz-grant-read" => [~s(id="bob")]}))

    assert grants == [%{grantee: :everyone, permission: :get}]
  end

  test "no ACL headers yields no grants" do
    assert Acl.grants(getter(%{})) == []
  end
end
