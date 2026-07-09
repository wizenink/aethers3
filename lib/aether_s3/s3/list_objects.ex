defmodule AetherS3.S3.ListObjects do
  @moduledoc """
  Pure LIST paging: given a bucket's full, sorted `[{key, meta}]` and the request
  options, compute a single page (`prefix`/`delimiter`/`max-keys`/`after` cursor).

  The list is already materialized and sorted upstream (`Coordinator.list/1`
  scatter-gathers every node then sorts), so paging is just filter → optionally
  fold keys into common prefixes → slice. Both `Contents` and `CommonPrefixes`
  count toward `max-keys`, matching S3.
  """

  @default_max 1000
  @max 1000

  @type row :: {:key, String.t(), map()} | {:prefix, String.t()}

  @type result :: %{
          keys: [{String.t(), map()}],
          common_prefixes: [String.t()],
          next_token: String.t() | nil,
          truncated: boolean(),
          key_count: non_neg_integer(),
          max_keys: non_neg_integer(),
          prefix: String.t(),
          delimiter: String.t() | nil,
          start_after: String.t() | nil
        }

  @doc """
  Compute one page.

  Options:
    * `:prefix` — keep only keys starting with it (`""` = all)
    * `:delimiter` — fold keys that share a run up to the first delimiter (after the
      prefix) into a single `CommonPrefixes` entry
    * `:max_keys` — page size, clamped to `0..1000` (default 1000)
    * `:after` — resume strictly after this key/prefix (continuation token / marker /
      start-after, already decoded)
  """
  @spec paginate([{String.t(), map()}], keyword()) :: result()
  def paginate(entries, opts \\ []) do
    prefix = opts[:prefix] || ""
    delimiter = opts[:delimiter]
    max_keys = clamp(opts[:max_keys])
    after_key = opts[:after]

    rows =
      entries
      |> Enum.filter(fn {k, _m} -> String.starts_with?(k, prefix) end)
      |> group(prefix, delimiter)
      |> Enum.filter(fn row -> row_key(row) > (after_key || "") end)
      |> Enum.sort_by(&row_key/1)

    {page, rest} = Enum.split(rows, max_keys)
    truncated = rest != []

    %{
      keys: for({:key, k, m} <- page, do: {k, m}),
      common_prefixes: for({:prefix, p} <- page, do: p),
      next_token: if(truncated and page != [], do: row_key(List.last(page))),
      truncated: truncated,
      key_count: length(page),
      max_keys: max_keys,
      prefix: prefix,
      delimiter: delimiter,
      start_after: after_key
    }
  end

  @doc "Opaque continuation token = base64 of the resume key/prefix."
  def encode_token(nil), do: nil
  def encode_token(key), do: Base.url_encode64(key)

  @doc "Decode a continuation token back to a resume key; tolerate a raw (unencoded) key."
  def decode_token(nil), do: nil

  def decode_token(token) do
    case Base.url_decode64(token) do
      {:ok, key} -> key
      :error -> token
    end
  end

  # No delimiter: every kept key is a row.
  defp group(entries, _prefix, nil), do: Enum.map(entries, fn {k, m} -> {:key, k, m} end)

  # With a delimiter, a key whose remainder (past the prefix) contains the delimiter
  # collapses to a common prefix = prefix ++ up-to-and-including that first delimiter.
  defp group(entries, prefix, delimiter) do
    entries
    |> Enum.map(fn {k, m} ->
      rest = String.replace_prefix(k, prefix, "")

      case String.split(rest, delimiter, parts: 2) do
        [_no_delimiter] -> {:key, k, m}
        [head, _tail] -> {:prefix, prefix <> head <> delimiter}
      end
    end)
    |> Enum.uniq()
  end

  defp row_key({:key, k, _m}), do: k
  defp row_key({:prefix, p}), do: p

  defp clamp(n) when is_integer(n) and n >= 0, do: min(n, @max)
  defp clamp(_), do: @default_max
end
