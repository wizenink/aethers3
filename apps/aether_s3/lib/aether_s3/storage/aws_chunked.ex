defmodule AetherS3.Storage.AwsChunked do
  @moduledoc """
  Streaming decoder for the S3 `aws-chunked` body encoding.

  AWS SDK v2, the current aws-cli, and minio-go (hence warp) upload with this
  framing by default — the object bytes are wrapped in HTTP-chunk-like frames:

      <hex-size>[;chunk-signature=<sig>]\\r\\n
      <size bytes of data>\\r\\n
      ... repeated ...
      0[;chunk-signature=<sig>]\\r\\n
      [<trailer-header>:<value>\\r\\n ...]
      \\r\\n

  Signalled by `Content-Encoding: aws-chunked` and/or an
  `x-amz-content-sha256: STREAMING-*` header. Without decoding, the framing bytes
  are stored as part of the object, so it reads back larger and corrupted.

  Per-chunk signatures and trailer checksums are parsed past but **not** verified:
  the request-level SigV4 signature (computed over the `STREAMING-*` content-sha256
  placeholder) already authenticates the request. Verifying the rolling
  chunk-signature / trailer checksums for end-to-end body integrity is a separate,
  deferred hardening step.

  Stateful, because the socket reader delivers arbitrary byte boundaries that
  don't align to chunk frames: feed each `read_body` segment through `decode/2`
  and carry the returned state forward.
  """

  @enforce_keys [:phase]
  defstruct phase: :size, buf: "", remaining: 0

  @type t :: %__MODULE__{
          phase: :size | :data | :crlf | :trailer,
          buf: binary,
          remaining: non_neg_integer
        }

  @doc "Whether this request body is aws-chunked encoded."
  @spec encoded?(Plug.Conn.t()) :: boolean
  def encoded?(conn) do
    sha = conn |> Plug.Conn.get_req_header("x-amz-content-sha256") |> List.first() || ""
    enc = conn |> Plug.Conn.get_req_header("content-encoding") |> List.first() || ""
    String.starts_with?(sha, "STREAMING-") or String.contains?(enc, "aws-chunked")
  end

  @spec new() :: t
  def new, do: %__MODULE__{phase: :size}

  @doc """
  Decode one segment of framed body, returning the decoded object bytes produced
  so far and the state to carry into the next segment. Any bytes that straddle a
  frame boundary are retained in the state until completed.
  """
  @spec decode(t, binary) :: {:ok, iodata, t} | {:error, term}
  def decode(%__MODULE__{} = st, data) when is_binary(data) do
    run(%{st | buf: st.buf <> data}, [])
  end

  # Everything after the terminating 0-chunk is trailer headers we don't verify.
  defp run(%{phase: :trailer} = st, acc), do: {:ok, Enum.reverse(acc), %{st | buf: ""}}

  # Chunk-size line: <hex>[;ext...]\r\n — parse the hex up to the first ';'.
  defp run(%{phase: :size, buf: buf} = st, acc) do
    case :binary.split(buf, "\r\n") do
      [_incomplete] ->
        {:ok, Enum.reverse(acc), st}

      [line, rest] ->
        case parse_size(line) do
          :error -> {:error, :bad_chunk_size}
          0 -> run(%{st | phase: :trailer, buf: rest, remaining: 0}, acc)
          n -> run(%{st | phase: :data, buf: rest, remaining: n}, acc)
        end
    end
  end

  # Chunk data: emit up to `remaining` bytes, then expect the trailing CRLF.
  defp run(%{phase: :data, buf: buf, remaining: rem} = st, acc) do
    case byte_size(buf) do
      0 ->
        {:ok, Enum.reverse(acc), st}

      avail when avail < rem ->
        {:ok, Enum.reverse([buf | acc]), %{st | buf: "", remaining: rem - avail}}

      _ ->
        <<data::binary-size(^rem), rest::binary>> = buf
        run(%{st | phase: :crlf, buf: rest, remaining: 0}, [data | acc])
    end
  end

  # The CRLF that terminates a chunk's data (may arrive split across segments).
  defp run(%{phase: :crlf, buf: buf} = st, acc) do
    case buf do
      <<"\r\n", rest::binary>> -> run(%{st | phase: :size, buf: rest}, acc)
      <<"\r">> -> {:ok, Enum.reverse(acc), st}
      <<>> -> {:ok, Enum.reverse(acc), st}
      _ -> {:error, :bad_chunk_terminator}
    end
  end

  defp parse_size(line) do
    hex = line |> :binary.split(";") |> hd() |> String.trim()

    case Integer.parse(hex, 16) do
      {n, ""} when n >= 0 -> n
      _ -> :error
    end
  end
end
