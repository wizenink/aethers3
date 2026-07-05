defmodule AetherS3.Plug.Authorize do
  @moduledoc """
  Per-bucket authorization. Runs after `AetherS3.Plug.SigV4` (which stashed
  `conn.assigns.identity`), before routing. Decides allow/deny from the identity,
  the target bucket's owner + grants, and the operation:

    * admin identity -> allow anything
    * bucket owner   -> allow anything on that bucket
    * otherwise, the bucket's grants must allow the operation's permission
      (`:read` for GET/HEAD, `:write` for object PUT/POST/DELETE) for one of the
      caller's principals: their user, any group they belong to, or `:everyone`
      (see `AetherS3.Auth.Grants`).

  Anonymous is simply an identity with no user (its principals are just
  `:everyone`), so it can only do what an `:everyone` grant permits. Canned ACLs
  (`public-read`, …) are sugar over grants and evaluate the same way.

  Care points:
    * A request for a NONEXISTENT bucket is allowed through so the router can
      answer 404 NoSuchBucket instead of leaking via a 403.
    * Creating a bucket (PUT on a name with no record yet) needs an authenticated
      identity but no ownership; PUT on an existing name is owner-only.
    * DeleteBucket is owner/admin-only — never granted.
    * When `require_auth` is off the whole layer is bypassed (see SigV4 plug); we
      never fabricate an admin identity for that case.

  The reserved multipart bucket never reaches here — `Plug.ReservedBucket` 404s
  it earlier in the pipeline.
  """
  @behaviour Plug
  import Plug.Conn
  alias AetherS3.ControlPlane.Store, as: ControlPlane
  alias AetherS3.Auth.Grants
  alias AetherS3.S3.XML

  @canned_acls ["private", "public-read", "public-read-write"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:aether_s3, :require_auth, true) do
      if allowed?(conn), do: conn, else: deny(conn)
    else
      conn
    end
  end

  defp allowed?(conn) do
    identity = conn.assigns[:identity]

    case conn.path_info do
      [] -> true
      [bucket] -> bucket_op(identity, bucket, conn.method)
      [bucket | _key] -> object_op(identity, bucket, conn.method)
    end
  end

  defp bucket_op(identity, bucket, method) do
    cond do
      admin?(identity) ->
        true

      method in ["GET", "HEAD"] ->
        read_allowed?(identity, bucket)

      method == "PUT" ->
        # New name -> creating: any authenticated identity may. Existing name ->
        # idempotent re-create / ?acl / etc: owner-only.
        case ControlPlane.get_bucket(bucket) do
          nil -> authenticated?(identity)
          b -> owner?(identity, b)
        end

      method == "DELETE" ->
        owner_only?(identity, bucket)

      true ->
        false
    end
  end

  defp object_op(identity, bucket, method) do
    cond do
      admin?(identity) -> true
      method in ["GET", "HEAD"] -> read_allowed?(identity, bucket)
      method in ["PUT", "POST", "DELETE"] -> write_allowed?(identity, bucket)
      true -> false
    end
  end

  defp read_allowed?(identity, bucket), do: granted?(identity, bucket, :read)
  defp write_allowed?(identity, bucket), do: granted?(identity, bucket, :write)

  defp granted?(identity, bucket, required) do
    case ControlPlane.get_bucket(bucket) do
      # missing bucket: let the router answer 404, not 403
      nil ->
        true

      record ->
        owner?(identity, record) or
          Grants.allows?(Grants.of(record), principals(identity), required)
    end
  end

  defp owner_only?(identity, bucket) do
    case ControlPlane.get_bucket(bucket) do
      nil -> true
      b -> owner?(identity, b)
    end
  end

  defp principals(%{user: user} = identity),
    do: Grants.principals(identity, ControlPlane.groups_of(user))

  defp principals(_anonymous), do: Grants.principals(:anonymous, [])

  defp admin?(%{admin: true}), do: true
  defp admin?(_), do: false

  defp authenticated?(%{user: _}), do: true
  defp authenticated?(_), do: false

  defp owner?(%{user: user}, %{owner: owner}) when is_binary(owner), do: user == owner
  defp owner?(_, _), do: false

  @doc "The set of canned ACLs a client may request (used by the router)."
  def canned_acls, do: @canned_acls

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(403, XML.error("AccessDenied", "Access denied.", conn.request_path))
    |> halt()
  end
end
