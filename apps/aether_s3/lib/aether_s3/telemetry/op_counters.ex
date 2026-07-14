defmodule AetherS3.Telemetry.OpCounters do
  @moduledoc """
  Per-node cumulative operation counters (lock-free `:counters`), incremented from
  a telemetry handler and exposed in `Cluster.Status.local_view` so the console can
  diff them between polls into per-node, per-type *rates* for the flow viz.

  This is a cheap, bounded alternative to streaming individual events: the counter
  bump is a single atomic add (no network, no fan-out), and the console reads
  aggregate deltas — so it can't explode under high write/op volume.
  """

  @slots %{put: 1, repair: 2, read_repair: 3, shed: 4}
  @pt_key __MODULE__

  # {telemetry event, counter slot}
  @events [
    {[:aether, :object, :put], :put},
    {[:aether, :anti_entropy, :repair], :repair},
    {[:aether, :read_repair], :read_repair},
    {[:aether, :anti_entropy, :shed], :shed}
  ]

  @doc "Create the counters and attach the telemetry handler. Called once at startup."
  def setup do
    ref = :counters.new(map_size(@slots), [:write_concurrency])
    :persistent_term.put(@pt_key, ref)

    :telemetry.detach(__MODULE__)

    :telemetry.attach_many(
      "#{__MODULE__}",
      Enum.map(@events, &elem(&1, 0)),
      &__MODULE__.handle/4,
      nil
    )

    :ok
  end

  @doc false
  def handle(event, measurements, _meta, _cfg) do
    with slot when is_integer(slot) <- slot_for(event),
         ref when ref != nil <- ref() do
      :counters.add(ref, slot, Map.get(measurements, :count, 1))
    end
  end

  @doc "Current cumulative counts per op type."
  def read do
    case ref() do
      nil -> Map.new(@slots, fn {k, _} -> {k, 0} end)
      ref -> Map.new(@slots, fn {k, i} -> {k, :counters.get(ref, i)} end)
    end
  end

  defp ref, do: :persistent_term.get(@pt_key, nil)

  defp slot_for(event) do
    case List.keyfind(@events, event, 0) do
      {_, name} -> @slots[name]
      nil -> nil
    end
  end
end
