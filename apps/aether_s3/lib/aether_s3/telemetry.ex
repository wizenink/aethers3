defmodule AetherS3.Telemetry do
  @moduledoc """
  Metrics supervisor. Starts the Prometheus core reporter (aggregates telemetry
  events into an ETS table scraped by `AetherS3.AdminRouter` at `/metrics`) and a
  poller that periodically emits AetherS3-specific gauges. VM metrics come from
  `telemetry_poller`'s own default poller; HTTP metrics come from Bandit's
  built-in `[:bandit, :request, :stop]` event.

  Metric set is intentionally small and hand-picked (a hand-crafted Grafana
  dashboard can be built against these names later). Add domain counters by
  emitting `:telemetry.execute/3` at the call site and a definition here.
  """
  use Supervisor
  import Telemetry.Metrics

  alias AetherS3.ObjectMeta.Store, as: ObjectMeta

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    # Lock-free per-node op counters (read by Cluster.Status for the console's rate viz).
    AetherS3.Telemetry.OpCounters.setup()

    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics()},
      {:telemetry_poller,
       measurements: [{__MODULE__, :dispatch_cluster_metrics, []}],
       period: :timer.seconds(10),
       name: :aether_telemetry_poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Prometheus scrape text (delegated to by the admin router)."
  def scrape, do: TelemetryMetricsPrometheus.Core.scrape()

  defp metrics do
    [
      # --- HTTP (S3 API only; the admin port is filtered out) ---
      distribution("bandit.request.duration.milliseconds",
        event_name: [:bandit, :request, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:method, :status],
        tag_values: &http_tags/1,
        keep: &s3_request?/1,
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "S3 API request duration (its _count is the request total)"
      ),
      sum("bandit.request.resp_body_bytes",
        event_name: [:bandit, :request, :stop],
        measurement: :resp_body_bytes,
        keep: &s3_request?/1,
        unit: :byte,
        description: "Total bytes served over the S3 API"
      ),
      sum("bandit.request.req_body_bytes",
        event_name: [:bandit, :request, :stop],
        measurement: :req_body_bytes,
        keep: &s3_request?/1,
        unit: :byte,
        description: "Total request-body bytes received over the S3 API"
      ),

      # --- Object operations (event/measurement derived from the metric name) ---
      sum("aether.object.put.count",
        measurement: :count,
        tags: [:result, :kind],
        description: "Object/part writes, tagged ok|insufficient_replicas and object|part"
      ),
      sum("aether.object.put.bytes",
        measurement: :bytes,
        tags: [:result, :kind],
        unit: :byte,
        description: "Bytes written"
      ),
      sum("aether.object.read.count",
        measurement: :count,
        description: "Object reads (GET/HEAD)"
      ),
      sum("aether.object.delete.count", measurement: :count, description: "Object deletes"),

      # --- Self-healing & rebalancing (the interesting distributed activity) ---
      sum("aether.read_repair.count",
        measurement: :count,
        description: "Stale/missing replicas repaired on the read path"
      ),
      sum("aether.anti_entropy.repair.count",
        measurement: :count,
        description: "Objects pushed to a replica by the anti-entropy loop"
      ),
      sum("aether.anti_entropy.shed.count",
        measurement: :count,
        description: "Local copies shed after a ring change (rebalancing)"
      ),

      # --- Reaper (orphan cleanup) ---
      sum("aether.reaper.mpu.count",
        measurement: :count,
        description: "Abandoned multipart uploads reaped"
      ),
      sum("aether.reaper.staging.count",
        measurement: :count,
        description: "Orphaned staging temp files swept"
      ),

      # --- Scrub (bitrot integrity) ---
      sum("aether.scrub.ok.count", measurement: :count, description: "Blobs scrubbed intact"),
      sum("aether.scrub.healed.count",
        measurement: :count,
        description: "Corrupt/missing blobs healed from a replica"
      ),
      sum("aether.scrub.unrecoverable.count",
        measurement: :count,
        description: "Corrupt/missing blobs with no good replica (data loss)"
      ),
      sum("aether.read_verify.fail.count",
        measurement: :count,
        description: "Full reads that failed read-time integrity verification"
      ),

      # --- Multipart lifecycle ---
      sum("aether.multipart.initiated.count", measurement: :count),
      sum("aether.multipart.completed.count", measurement: :count),
      sum("aether.multipart.aborted.count", measurement: :count),

      # --- BEAM VM (emitted by telemetry_poller's default poller) ---
      last_value("vm.memory.total", unit: :byte, description: "Total VM memory"),
      last_value("vm.memory.processes", unit: :byte, description: "Process memory"),
      last_value("vm.memory.binary", unit: :byte, description: "Binary memory"),
      last_value("vm.memory.ets", unit: :byte, description: "ETS memory"),
      last_value("vm.total_run_queue_lengths.total", description: "Total run-queue length"),
      last_value("vm.system_counts.process_count", description: "Live processes"),
      last_value("vm.system_counts.port_count", description: "Open ports"),
      last_value("vm.system_counts.atom_count", description: "Atoms"),

      # --- AetherS3 cluster/storage gauges (see dispatch_cluster_metrics/0) ---
      last_value("aether.cluster.nodes",
        description: "Connected BEAM nodes, including self"
      ),
      last_value("aether.cluster.khepri_leader",
        description: "1 if this node knows a Khepri/Raft leader, else 0"
      ),
      last_value("aether.cluster.objects",
        description: "Object-metadata entries held locally (replicas included)"
      )
    ]
  end

  @doc false
  # Periodic gauge sampler. Everything here must be cheap and non-blocking — the
  # leader lookup is an ETS read (never the blocking :khepri_cluster.nodes/0).
  def dispatch_cluster_metrics do
    measurements = %{
      nodes: length(Node.list()) + 1,
      khepri_leader: khepri_leader_gauge(),
      objects: object_count()
    }

    :telemetry.execute([:aether, :cluster], measurements, %{})
  end

  # Telemetry starts before the metadata store (so its handlers are up first), and
  # the store may be briefly down/restarting — a metric sample must never crash the
  # poller, so fall back to 0 rather than propagating a :noproc exit.
  defp object_count do
    ObjectMeta.count()
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp khepri_leader_gauge do
    case :ra_leaderboard.lookup_leader(:khepri) do
      {:khepri, _leader} -> 1
      _ -> 0
    end
  end

  # Tag S3 requests by method + status; unknowns (no conn yet) fall back sanely.
  defp http_tags(%{conn: conn}), do: %{method: conn.method, status: conn.status}
  defp http_tags(_), do: %{method: "unknown", status: 0}

  # Keep only requests that arrived on the S3 API port (drop admin-port traffic,
  # so health/readiness probes don't flood the request histogram).
  defp s3_request?(%{conn: %{port: port}}),
    do: port == Application.get_env(:aether_s3, :port, 9000)

  defp s3_request?(_), do: false
end
