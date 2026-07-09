defmodule AetherS3.Plug.ReservedBucket do
  @moduledoc """
  Rejects client HTTP access to the reserved multipart bucket, as parts are an internal implmentation detail
  """

  @behaviour Plug
  import Plug.Conn
  alias AetherS3.Storage.Multipart
  alias AetherS3.S3.XML

  @mpu_bucket Multipart.bucket()
  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.path_info do
      [bucket | _] when bucket == @mpu_bucket ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(
          404,
          XML.error("NoSuchBucket", "The specified bucket does not exist.", conn.request_path)
        )
        |> Plug.Conn.halt()

      _ ->
        conn
    end
  end
end
