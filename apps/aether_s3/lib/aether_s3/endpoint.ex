defmodule AetherS3.Endpoint do
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts) do
    opts
  end

  @impl true
  def call(conn, _opts) do
    send_resp(conn, 200, "AetherS3 is alive\n")
  end
end
