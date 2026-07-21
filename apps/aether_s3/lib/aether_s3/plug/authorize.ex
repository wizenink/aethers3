defmodule AetherS3.Plug.Authorize do
  @moduledoc """
  Per-bucket authorization. Runs after `AetherS3.Plug.SigV4` (which stashed
  `conn.assigns.identity`), before routing. Decides allow/deny from the identity,
  the target bucket's owner + grants, and the operation:

    * admin identity -> allow anything
    * bucket owner   -> allow anything on that bucket
    * otherwise, the bucket's grants must allow the operation's permission for one
      of the caller's principals (their user, any group they belong to, or
      `:everyone`): `:list` to list/HEAD the bucket, `:get` to download/HEAD an
      object, `:write` for object PUT/POST/DELETE (see `AetherS3.Auth.Grants`).

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
      [] ->
        true

      [bucket] ->
        bucket_op(identity, bucket, conn.method)

      [bucket | key] ->
        acl? = Map.has_key?(fetch_query_params(conn).query_params, "acl")
        object_op(identity, bucket, Enum.join(key, "/"), conn.method, acl?)
    end
  end

  defp bucket_op(identity, bucket, method) do
    cond do
      admin?(identity) ->
        true

      method in ["GET", "HEAD"] ->
        # Listing / HEAD-ing the bucket is the :list permission (not :get, so a
        # public-read bucket doesn't leak its index). Bucket-wide grants only —
        # scoped grants are object-level and never grant listing.
        granted_bucket?(identity, bucket, :list)

      method == "PUT" ->
        # New name -> creating: any authenticated identity may. Existing name ->
        # idempotent re-create / ?acl / etc: owner-only.
        case ControlPlane.get_bucket(bucket) do
          nil -> authenticated?(identity)
          b -> owner?(identity, b)
        end

      method == "DELETE" ->
        owner_only?(identity, bucket)

      method == "POST" ->
        # Bulk delete (DeleteObjects) — the keys aren't parsed yet, so gate on
        # bucket-wide write (owner/admin or a bucket-wide :write grant). Identities
        # with only narrower per-key grants use individual DELETEs (per-key gated);
        # per-key authz for bulk delete is a follow-up.
        granted_bucket?(identity, bucket, :write)

      true ->
        false
    end
  end

  defp object_op(identity, bucket, key, method, acl?) do
    cond do
      admin?(identity) -> true
      # Reading/setting an object or prefix ACL is managing sharing -> owner/admin only.
      acl? -> owner_only?(identity, bucket)
      method in ["GET", "HEAD"] -> granted?(identity, bucket, key, :get)
      method in ["PUT", "POST", "DELETE"] -> granted?(identity, bucket, key, :write)
      true -> false
    end
  end

  defp granted?(identity, bucket, key, required) do
    case ControlPlane.get_bucket(bucket) do
      # missing bucket: let the router answer 404, not 403
      nil ->
        true

      record ->
        owner?(identity, record) or
          Grants.allows_for_key?(record, principals(identity), key, required)
    end
  end

  # Bucket-level permission (listing) — bucket-wide grants only, no scoped grants.
  defp granted_bucket?(identity, bucket, required) do
    case ControlPlane.get_bucket(bucket) do
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
