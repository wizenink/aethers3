defmodule AetherS3.S3.Acl do
  @moduledoc """
  Parse S3 ACL request inputs (on `PUT /bucket?acl` or at bucket create) into
  `AetherS3.Auth.Grants` grants. Supports the canned `x-amz-acl` header (sugar
  over `:everyone` grants) and the explicit grant headers, whose values are
  comma-separated grantees:

      x-amz-grant-read:         id="bob", group="eng"
      x-amz-grant-write:        id="carol"
      x-amz-grant-full-control: everyone

  Grantee tokens: `id="u"` or `user="u"` -> `{:user, u}`, `group="g"` ->
  `{:group, g}`, and `everyone` (or an AllUsers URI) -> `:everyone`.
  """
  alias AetherS3.Auth.Grants
  alias AetherS3.S3.XML

  @grant_headers %{
    "x-amz-grant-read" => :read,
    "x-amz-grant-write" => :write,
    "x-amz-grant-full-control" => :full
  }

  @doc """
  Build grants from a header getter (`name -> [values]`, e.g.
  `&Plug.Conn.get_req_header(conn, &1)`). A canned `x-amz-acl` wins if present;
  otherwise the explicit `x-amz-grant-*` headers are parsed.
  """
  def grants(getter) do
    case getter.("x-amz-acl") do
      [canned | _] -> Grants.canned(canned)
      _ -> from_grant_headers(getter)
    end
  end

  defp from_grant_headers(getter) do
    for {header, permission} <- @grant_headers,
        value <- getter.(header),
        grantee <- parse_grantees(value) do
      %{grantee: grantee, permission: permission}
    end
  end

  @doc "Parse one grant header's value into a list of grantees."
  def parse_grantees(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> parse_grantee()))
    |> Enum.reject(&is_nil/1)
  end

  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"

  @doc """
  Serialize `grants` as an S3 `AccessControlPolicy` document owned by `owner`.

  The mapping is approximate — our model (list/get/write/full over
  user/group/everyone) is richer than S3's ACL vocabulary:

    * permission: `:get`/`:list`/legacy `:read` -> `READ`, `:write` -> `WRITE`,
      `:full` -> `FULL_CONTROL`
    * grantee: `{:user, u}` -> `CanonicalUser` with `<ID>u</ID>`, `:everyone` ->
      the AllUsers `Group`, `{:group, g}` -> a `Group` in our own URI namespace
      (non-standard — S3 has no arbitrary groups).
  """
  def to_xml(owner, grants) do
    owner = owner || ""

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <AccessControlPolicy><Owner><ID>#{XML.escape(owner)}</ID><DisplayName>#{XML.escape(owner)}</DisplayName></Owner><AccessControlList>#{Enum.map_join(grants, &grant_xml/1)}</AccessControlList></AccessControlPolicy>
    """
  end

  defp grant_xml(%{grantee: grantee, permission: permission}) do
    "<Grant>#{grantee_xml(grantee)}<Permission>#{s3_permission(permission)}</Permission></Grant>"
  end

  defp grantee_xml({:user, u}),
    do:
      ~s(<Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser"><ID>#{XML.escape(u)}</ID><DisplayName>#{XML.escape(u)}</DisplayName></Grantee>)

  defp grantee_xml(:everyone),
    do:
      ~s(<Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group"><URI>#{@all_users}</URI></Grantee>)

  defp grantee_xml({:group, g}),
    do:
      ~s(<Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group"><URI>urn:aether:group:#{XML.escape(g)}</URI></Grantee>)

  defp s3_permission(:write), do: "WRITE"
  defp s3_permission(:full), do: "FULL_CONTROL"
  defp s3_permission(_), do: "READ"

  defp parse_grantee("everyone"), do: :everyone

  defp parse_grantee(token) do
    cond do
      String.contains?(token, "AllUsers") ->
        :everyone

      true ->
        case Regex.run(~r/^(id|user|group)\s*=\s*"?([^"]+?)"?$/, token) do
          [_, kind, val] when kind in ["id", "user"] -> {:user, val}
          [_, "group", val] -> {:group, val}
          _ -> nil
        end
    end
  end
end
