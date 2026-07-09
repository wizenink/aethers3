defmodule AetherS3.Auth.Grants do
  @moduledoc """
  Pure bucket-grant model and evaluation. A grant is `%{grantee, permission}` —
  effectively an *allow statement*, so this generalizes toward a full policy
  engine later (explicit deny, wildcards, and conditions being the future
  extensions) rather than being a throwaway.

      grantee    :: {:user, name} | {:group, name} | :everyone
      permission :: :list | :get | :write | :full

  `:list` covers listing/HEAD-ing a bucket, `:get` covers downloading/HEAD-ing an
  object, `:write` covers object PUT/POST/DELETE, `:full` covers all three.
  Splitting list from get is deliberate: a `public-read` bucket exposes object
  downloads (`:get`) without exposing its index (`:list`). A legacy `:read`
  permission (from before the split) is still honored as list + get.

  Ownership/admin and bucket-level create/delete are decided by the Authorize plug
  BEFORE consulting grants — this module only answers "do the bucket's grants
  allow this operation for this caller?".
  """

  @type grantee :: {:user, String.t()} | {:group, String.t()} | :everyone
  @type permission :: :list | :get | :write | :full
  @type grant :: %{grantee: grantee, permission: permission}

  @doc "Does a held permission cover the one an operation requires?"
  @spec covers?(permission | :read, permission) :: boolean
  def covers?(:full, _), do: true
  def covers?(:read, :list), do: true
  def covers?(:read, :get), do: true
  def covers?(:list, :list), do: true
  def covers?(:get, :get), do: true
  def covers?(:write, :write), do: true
  def covers?(_, _), do: false

  @doc """
  The set of grantees a caller embodies: their own user, each group they belong
  to, and `:everyone`. Anonymous callers embody only `:everyone`.
  """
  @spec principals(map() | atom(), [String.t()]) :: MapSet.t(grantee)
  def principals(%{user: user}, groups) do
    MapSet.new([{:user, user}, :everyone | Enum.map(groups, &{:group, &1})])
  end

  def principals(_anonymous, _groups), do: MapSet.new([:everyone])

  @doc "Do any of `grants` allow `required` for one of the caller's `principals`?"
  @spec allows?([grant], MapSet.t(grantee), permission) :: boolean
  def allows?(grants, principals, required) do
    Enum.any?(grants, fn %{grantee: g, permission: p} ->
      MapSet.member?(principals, g) and covers?(p, required)
    end)
  end

  @doc """
  Does the bucket allow `required` for `key`? Bucket-wide grants apply to every
  key; a scoped grant applies only to keys its `scope` matches. Allowed if either
  path permits it for one of the caller's `principals`.
  """
  @spec allows_for_key?(map(), MapSet.t(grantee), String.t(), permission) :: boolean
  def allows_for_key?(record, principals, key, required) do
    allows?(of(record), principals, required) or
      Enum.any?(scoped(record), fn %{scope: scope, grants: grants} ->
        scope_matches?(scope, key) and allows?(grants, principals, required)
      end)
  end

  @doc "Does `scope` cover `key`? `*` = any key; a trailing `*` = prefix; else exact."
  @spec scope_matches?(String.t(), String.t()) :: boolean
  def scope_matches?("*", _key), do: true

  def scope_matches?(scope, key) do
    if String.ends_with?(scope, "*") do
      String.starts_with?(key, String.trim_trailing(scope, "*"))
    else
      key == scope
    end
  end

  @doc "A bucket record's grants, translating a legacy canned `:acl` if present."
  @spec of(map()) :: [grant]
  def of(%{grants: grants}) when is_list(grants), do: grants
  def of(%{acl: acl}), do: canned(acl)
  def of(_), do: []

  @doc "A bucket record's scoped (per key/prefix) grant entries, `[]` if none."
  @spec scoped(map()) :: [%{scope: String.t(), grants: [grant]}]
  def scoped(record), do: Map.get(record, :scoped_grants) || []

  @doc "Translate a canned ACL name into equivalent grants (sugar over :everyone)."
  @spec canned(String.t()) :: [grant]
  def canned("public-read"), do: [%{grantee: :everyone, permission: :get}]

  def canned("public-read-write"),
    do: [%{grantee: :everyone, permission: :get}, %{grantee: :everyone, permission: :write}]

  def canned(_), do: []
end
