defmodule AetherS3.Shutdown do
  @key {__MODULE__, :draining}
  def begin_draining, do: :persistent_term.put(@key, true)
  def draining?, do: :persistent_term.get(@key, false)
end
