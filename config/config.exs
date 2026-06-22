import Config

config :logger, :default_formatter, format: "$time $node [$level] $message\n"

config :logger, level: :info

# Test environment: isolate data on disk and skip SigV4 so router tests can
# exercise S3 semantics directly. Auth correctness has dedicated unit tests
# (test/aether_s3/auth/sigv4_test.exs) against the AWS reference vector.
if config_env() == :test do
  config :aether_s3, :data_dir, "tmp/test_data"
  config :aether_s3, :require_auth, false
end
