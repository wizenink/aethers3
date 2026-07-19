defmodule AetherS3.Tracing.Sampler do
  @moduledoc """
  Trace sampler that drops the operational-probe endpoints so Prometheus scrapes
  and load-balancer health checks don't flood the trace backend, then delegates
  every other decision to a wrapped sampler (parent-based, honoring
  `OTEL_TRACES_SAMPLER_ARG`).

  `opentelemetry_bandit` instruments *both* Bandit listeners — the S3 API and the
  admin port — and there's no per-listener filter, so we drop by request path
  here instead. `/admin/*` and `/whoami` are real operations and stay traced; only
  the high-frequency probes (`/health`, `/ready`, `/metrics`, `/cluster`) are
  dropped. Configured as the SDK sampler in runtime.exs.
  """
  @behaviour :otel_sampler

  # Key opentelemetry_bandit sets for the request path (semantic conventions).
  @url_path :"url.path"
  @drop_paths ~w(/health /ready /ready/cp /metrics /cluster)

  @impl :otel_sampler
  def setup(opts) do
    %{
      delegate: :otel_sampler.new(Map.fetch!(opts, :delegate)),
      drop: :otel_sampler.new(:always_off)
    }
  end

  @impl :otel_sampler
  def description(_config), do: "aether_drop_operational_probes"

  @impl :otel_sampler
  def should_sample(ctx, trace_id, links, span_name, span_kind, attributes, config) do
    {mod, _desc, sampler_config} =
      if drop?(span_kind, attributes), do: config.drop, else: config.delegate

    mod.should_sample(ctx, trace_id, links, span_name, span_kind, attributes, sampler_config)
  end

  defp drop?(:server, attributes) when is_map(attributes),
    do: Map.get(attributes, @url_path) in @drop_paths

  defp drop?(_kind, _attributes), do: false
end
