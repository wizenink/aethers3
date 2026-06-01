import Config

# Runtime configuration — evaluated on every boot (dev, test, prod releases).
# A single S3 credential pair. Override via env vars in real deployments.
config :aether_s3, :credentials, %{
  System.get_env("AETHER_ACCESS_KEY", "AKIAEXAMPLE") =>
    System.get_env("AETHER_SECRET_KEY", "devsecret")
}
