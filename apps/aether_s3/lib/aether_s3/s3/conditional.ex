defmodule AetherS3.S3.Conditional do
  @moduledoc """
  Conditional-request preconditions (RFC 9110 §13) for object reads and writes:
  `If-Match`, `If-None-Match`, `If-Modified-Since`, `If-Unmodified-Since`.

  Pure: evaluates a request's headers against the object's stored metadata (or
  `nil` when the key is absent) and returns the outcome the caller turns into a
  response. Kept out of the router so the precedence rules are unit-testable
  without a socket.

  Precedence follows RFC 9110 §13.2.2 — `If-Match` wins over `If-Unmodified-Since`
  and `If-None-Match` wins over `If-Modified-Since`, so a date conditional is only
  consulted when its etag counterpart is absent.

  ## Conditional writes are best-effort, not atomic

  `evaluate_write/2` checks the precondition against metadata read at the start of
  the request. There is no cluster-wide compare-and-swap, so two concurrent
  conditional PUTs to the same key can both observe the pre-write state and both
  succeed — the usual write-conflict resolution (version vectors, then a
  deterministic tiebreak) then picks a winner. That makes these headers a guard
  against *sequential* clobbering (the common case: "create only if absent",
  "overwrite only what I read"), NOT a distributed lock. Real serialization would
  have to route every conditional write through the Raft control plane.
  """

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @doc """
  Whether the request carries a precondition that a WRITE must evaluate. Lets the
  caller skip the extra metadata read on the (overwhelmingly common) unconditional
  PUT path.
  """
  def write_conditions?(req_headers) do
    not is_nil(header(req_headers, "if-match")) or
      not is_nil(header(req_headers, "if-none-match"))
  end

  @doc """
  Evaluate READ preconditions (GET/HEAD) against an object's metadata. Only call
  this for an object that exists — a missing key is a 404 regardless.

    * `:ok` — serve the object
    * `:not_modified` — respond `304` (client's cached copy is current)
    * `:precondition_failed` — respond `412`
  """
  def evaluate_read(req_headers, meta) do
    with :ok <- read_if_match(req_headers, meta) do
      read_if_none_match(req_headers, meta)
    end
  end

  # If-Match wins over If-Unmodified-Since; neither present means no opinion.
  defp read_if_match(req_headers, meta) do
    case {header(req_headers, "if-match"), header(req_headers, "if-unmodified-since")} do
      {nil, nil} ->
        :ok

      {nil, since} ->
        # Fail only on a date we can parse AND that the object is newer than.
        case http_date(since) do
          {:ok, dt} -> if modified_since?(meta, dt), do: :precondition_failed, else: :ok
          :error -> :ok
        end

      {value, _} ->
        if match_etag?(value, meta), do: :ok, else: :precondition_failed
    end
  end

  # If-None-Match wins over If-Modified-Since.
  defp read_if_none_match(req_headers, meta) do
    case {header(req_headers, "if-none-match"), header(req_headers, "if-modified-since")} do
      {nil, nil} ->
        :ok

      {nil, since} ->
        case http_date(since) do
          {:ok, dt} -> if modified_since?(meta, dt), do: :ok, else: :not_modified
          :error -> :ok
        end

      {value, _} ->
        if match_etag?(value, meta), do: :not_modified, else: :ok
    end
  end

  @doc """
  Evaluate WRITE preconditions (PUT) against the key's CURRENT metadata, or `nil`
  when it does not exist yet.

    * `:ok` — proceed with the write
    * `:precondition_failed` — respond `412`
    * `:not_found` — respond `404` (`If-Match` on a key that does not exist)

  `If-None-Match: *` is create-if-absent; `If-Match: <etag>` is
  overwrite-only-if-unchanged. See the module note — this is not atomic.
  """
  def evaluate_write(req_headers, meta) do
    with :ok <- write_if_match(header(req_headers, "if-match"), meta) do
      write_if_none_match(header(req_headers, "if-none-match"), meta)
    end
  end

  defp write_if_match(nil, _meta), do: :ok
  defp write_if_match(_value, nil), do: :not_found

  defp write_if_match(value, meta),
    do: if(match_etag?(value, meta), do: :ok, else: :precondition_failed)

  defp write_if_none_match(nil, _meta), do: :ok
  # Absent key: "only if absent" (and any specific etag) is satisfied.
  defp write_if_none_match(_value, nil), do: :ok

  defp write_if_none_match(value, meta),
    do: if(match_etag?(value, meta), do: :precondition_failed, else: :ok)

  # `*` matches any existing object regardless of its etag. Otherwise compare
  # against each tag in the comma-separated list, ignoring the weak-validator
  # prefix and surrounding quotes (a multipart etag like "abc-3" compares as-is).
  defp match_etag?("*", _meta), do: true

  defp match_etag?(value, meta) do
    case Map.get(meta, :etag) do
      nil ->
        false

      etag ->
        value
        |> String.split(",")
        |> Enum.map(&normalize_tag/1)
        |> Enum.any?(&(&1 == etag))
    end
  end

  defp normalize_tag(tag) do
    tag
    |> String.trim()
    |> String.replace_prefix("W/", "")
    |> String.trim("\"")
  end

  # HTTP dates carry second resolution, so compare the stored timestamp truncated
  # to the second — otherwise an object written at .5s looks "modified since" a
  # header naming the very same second.
  defp modified_since?(meta, %DateTime{} = dt) do
    case Map.get(meta, :last_modified) do
      %DateTime{} = lm -> DateTime.compare(DateTime.truncate(lm, :second), dt) == :gt
      _ -> false
    end
  end

  # HTTP-date (RFC 9110 §5.6.7). Only IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT")
  # is parsed — the format every S3 client emits. The zone token must literally be
  # GMT, as the grammar requires: treating some other zone as UTC would silently
  # apply the precondition at the wrong instant. An unparseable value yields
  # `:error` and the caller IGNORES the header, which RFC 9110 §13.1.3 requires.
  defp http_date(value) do
    case value |> String.trim() |> String.split() do
      [_dow, d, mon, y, time, "GMT"] ->
        with {day, ""} <- Integer.parse(d),
             {year, ""} <- Integer.parse(y),
             %{^mon => month} <- @months,
             [hh, mm, ss] <- String.split(time, ":"),
             {h, ""} <- Integer.parse(hh),
             {m, ""} <- Integer.parse(mm),
             {s, ""} <- Integer.parse(ss),
             {:ok, date} <- Date.new(year, month, day),
             {:ok, t} <- Time.new(h, m, s) do
          DateTime.new(date, t, "Etc/UTC")
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # `If-Match`/`If-None-Match` are list-valued, so a client may legally split them
  # across repeated header lines; RFC 9110 §5.3 says that is equivalent to one
  # comma-joined value. Taking only the first occurrence would silently drop the
  # rest — and for an If-Match that means a 412 on a tag the client did send.
  # (The date conditionals aren't list-valued; if one is somehow repeated the join
  # simply fails to parse, and an unparseable date is ignored.)
  defp header(req_headers, name) do
    case for {^name, value} <- req_headers, do: value do
      [] -> nil
      [value] -> value
      values -> Enum.join(values, ",")
    end
  end
end
