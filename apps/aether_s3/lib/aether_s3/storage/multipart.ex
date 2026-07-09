defmodule AetherS3.Storage.Multipart do
  @moduledoc """
  Helpers for the multipart-upload object model.

  A completed multipart object is stored as a *manifest*: its metadata carries a
  `:parts` list, and the actual bytes live as ordinary replicated objects under a
  reserved bucket (`bucket/0`), keyed `"<upload_id>/<part_number>"`. Nothing is
  concatenated — GET streams the parts in order.

  NOTE: when auth/authorization lands, the reserved bucket must be made
  unreachable by clients (today nothing stops `GET /__mpu__/...`).
  """

  @bucket "__mpu__"

  @doc "Reserved bucket that backs multipart part objects."
  def bucket, do: @bucket

  @doc "Object key for a single part within an upload."
  def part_key(upload_id, part_number), do: "#{upload_id}/#{part_number}"

  @doc """
  A fresh, opaque upload id. No node affinity — the manifest model is fully
  stateless, so any node can serve any request for this upload.
  """
  def new_upload_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @doc "Builds the S3 multipart etag from the concatenated binary part md5s."
  def multipart_etag(parts_etag) do
    count = Enum.count(parts_etag)

    parts_hash =
      parts_etag
      |> Enum.map(&Base.decode16!(&1, case: :lower))
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    "#{parts_hash}-#{count}"
  end

  def init_key(upload_id), do: "#{upload_id}/_init"
end
