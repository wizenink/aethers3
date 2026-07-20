defmodule AetherS3.Storage.IntegrityError do
  @moduledoc """
  Raised mid-response when a blob fails read-time integrity verification, so the
  chunked reply is aborted (no terminating chunk) rather than completing as a
  successful read of corrupt bytes. The client sees a broken transfer and retries.
  """
  defexception message: "object failed read-time integrity verification"
end
