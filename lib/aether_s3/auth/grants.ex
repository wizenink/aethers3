defmodule AetherS3.Auth.Grants do
  @moduledoc """
  Pure bucket-grant model and evaluation. A grant is `%{grantee, permission}` —
  effectively an *allow statement*, so this generalizes toward a full policy
  engine later (explicit deny, wildcards, and conditions being the future
  extensions) rather than being a throwaway.

      grantee    :: {:user, name} | {:group, name} | :everyone
      permission :: :read | :write | :full

  `:read` covers GET/HEAD/list, `:write` covers object PUT/POST/DELETE, `:full`
  covers both. Ownership/admin and bucket-level create/delete are decided by the
  Authorize plug BEFORE consulting grants — this module only answers "do the
  bucket's grants allow this operation for this caller?".
  """

  @type grantee :: {:user, String.t()} | {:group, String.t()} | :everyone
  @type permission :: :read | :write | :full
  @type grant :: %{grantee: grantee, permission: permission}

  @doc "Does a held permission cover the one an operation requires?"
  @spec covers?(permission, permission) :: boolean
  def covers?(:full, _), do: true
  def covers?(:read, :read), do: true
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

  @doc "A bucket record's grants, translating a legacy canned `:acl` if present."
  @spec of(map()) :: [grant]
  def of(%{grants: grants}) when is_list(grants), do: grants
  def of(%{acl: acl}), do: canned(acl)
  def of(_), do: []

  @doc "Translate a canned ACL name into equivalent grants (sugar over :everyone)."
  @spec canned(String.t()) :: [grant]
  def canned("public-read"), do: [%{grantee: :everyone, permission: :read}]
  def canned("public-read-write"), do: [%{grantee: :everyone, permission: :full}]
  def canned(_), do: []
end
