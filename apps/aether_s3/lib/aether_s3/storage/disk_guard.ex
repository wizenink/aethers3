defmodule AetherS3.Storage.DiskGuard do
  @moduledoc """
  Per-node disk-space guard. Polls free space on the data directory and caches a
  `writable?` flag in `:persistent_term`; the write path checks it
  and rejects new object writes with `507` when free space falls below
  `:min_free_bytes`. The point is headroom: reject *object* writes with room to
  spare so the control plane (Khepri/Ra log) and metadata never run the disk dry
  — a fully full disk wedges Raft, which is far worse than a rejected PUT.

  Reads and deletes are never gated (a delete frees space). Opt-in via
  `:min_free_bytes` (env `AETHER_MIN_FREE_BYTES`) — disabled when unset, in which
  case `writable?/0` is always `true`. Absolute-bytes reserve, not a percent, so
  the headroom is fixed regardless of disk size. Measured with `df -Pk` (POSIX,
  portable) every `:disk_poll_ms` (default 10s).
  """
  use GenServer
  require Logger

  @flag {__MODULE__, :writable}
  @default_interval_ms :timer.seconds(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Whether the data disk has enough free space to accept new object writes."
  @spec writable?() :: boolean()
  def writable?, do: :persistent_term.get(@flag, true)

  @impl true
  def init(:ok) do
    case Application.get_env(:aether_s3, :min_free_bytes) do
      nil ->
        :ignore

      reserve ->
        interval = Application.get_env(:aether_s3, :disk_poll_ms, @default_interval_ms)
        dir = Application.get_env(:aether_s3, :data_dir, "tmp/aether_data")
        Logger.info("disk guard: reject writes below #{reserve} B free on #{dir}")
        state = %{reserve: reserve, interval: interval, dir: dir}
        poll(state)
        schedule(interval)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  defp poll(%{reserve: reserve, dir: dir}) do
    writable =
      case free_bytes(dir) do
        {:ok, free} -> free >= reserve
        # Can't measure (dir not created yet, df hiccup) -> fail open, don't wedge writes.
        :error -> true
      end

    was = :persistent_term.get(@flag, true)
    :persistent_term.put(@flag, writable)

    cond do
      was and not writable ->
        Logger.error("disk guard: LOW SPACE on #{dir} — rejecting writes (507)")

      not was and writable ->
        Logger.info("disk guard: space recovered on #{dir} — accepting writes")

      true ->
        :ok
    end
  end

  # Free bytes on the filesystem holding `dir`, via `df -Pk` (POSIX one-line
  # output, portable across Linux + macOS). The 4th column is available 1K-blocks.
  defp free_bytes(dir) do
    case System.cmd("df", ["-Pk", dir], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> String.split("\n") |> List.last() |> String.split() do
          [_fs, _blocks, _used, avail | _] ->
            case Integer.parse(avail) do
              {kb, _} -> {:ok, kb * 1024}
              _ -> :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)
end
