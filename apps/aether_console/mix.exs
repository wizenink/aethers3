defmodule AetherConsole.MixProject do
  use Mix.Project

  def project do
    [
      app: :aether_console,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AetherConsole.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # A lean web app: Phoenix LiveView served by Bandit, an HTTP client (req) for the
  # cluster's admin/S3 APIs. No Ecto/DB — the console holds no state of its own.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
