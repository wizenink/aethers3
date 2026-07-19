import Config

config :logger, :default_formatter, format: "$time $node [$level] $message\n"

# Build-time default. Overridable at boot via AETHER_LOG_LEVEL (see runtime.exs)
# and live on a running node via AetherS3.Config.set_log_level/1.
config :logger, level: :info

# Distributed tracing (OpenTelemetry) is off by default — no sampling, no export,
# zero hot-path cost. runtime.exs turns on OTLP export when
# OTEL_EXPORTER_OTLP_ENDPOINT is set.
config :opentelemetry, traces_exporter: :none, sampler: :always_off

# Test environment: isolate data on disk and skip SigV4 so router tests can
# exercise S3 semantics directly. Auth correctness has dedicated unit tests
# (test/aether_s3/auth/sigv4_test.exs) against the AWS reference vector.
if config_env() == :test do
  config :aether_s3, :data_dir, "tmp/test_data"
  config :aether_s3, :require_auth, false
end

# ── aether_console (Phoenix web UI) ─────────────────────────────────────────
config :aether_console, AetherConsoleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: AetherConsoleWeb.ErrorHTML], layout: false],
  pubsub_server: AetherConsole.PubSub,
  live_view: [signing_salt: "aetherLVsalt01"]

# Admin base URLs the console talks to (comma-separated). Overridden at runtime.
config :aether_console, :cluster_nodes, ["http://localhost:9001"]
# Bearer token for the cluster's /admin API (users/keys/groups/buckets). Runtime-set.
config :aether_console, :admin_token, nil
# How operators authenticate to the console: :cluster (log in as a cluster identity)
# is the only strategy today; :oidc is reserved. Overridden by AETHER_CONSOLE_AUTH.
config :aether_console, :auth_strategy, :cluster

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.23.0",
  aether_console: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../apps/aether_console/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

if config_env() == :dev do
  config :aether_console, AetherConsoleWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4000],
    secret_key_base: "dev_only_secret_key_base_padding_to_sixty_four_bytes_minimum_xxxxxxxx",
    debug_errors: true,
    check_origin: false,
    watchers: [
      esbuild: {Esbuild, :install_and_run, [:aether_console, ~w(--sourcemap=inline --watch)]}
    ]
end

if config_env() == :test do
  # The endpoint isn't served in tests, but ConnTest still needs a secret_key_base
  # to sign session cookies.
  config :aether_console, AetherConsoleWeb.Endpoint,
    secret_key_base: "test_only_secret_key_base_padding_to_sixty_four_bytes_minimum_xxxxxx",
    server: false
end
