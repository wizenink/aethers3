defmodule AetherS3.MixProject do
  use Mix.Project

  def project do
    [
      app: :aether_s3,
      version: "0.1.0",
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
      {:saxy, "~> 1.6"}
    ]
  end
end
