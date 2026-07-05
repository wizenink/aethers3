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
