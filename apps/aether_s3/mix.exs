defmodule AetherS3.MixProject do
  use Mix.Project

  def project do
    [
      app: :aether_s3,
      version: "0.8.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {AetherS3.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:cubdb, "~> 2.0"},
      {:saxy, "~> 1.6"},
      {:khepri, "~> 0.18.0"},
      {:libcluster, "~> 3.5"},
      {:toml, "~> 0.7"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      {:telemetry_poller, "~> 1.1"},
      # Distributed tracing (OpenTelemetry). Exporter is inert unless
      # OTEL_EXPORTER_OTLP_ENDPOINT is set (see runtime.exs), so this adds no
      # overhead by default.
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_bandit, "~> 0.2"}
    ]
  end
end
