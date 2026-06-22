defmodule AetherS3.MixProject do
  use Mix.Project

  def project do
    [
      app: :aether_s3,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # `mix rel` builds the release, working around a bug in khepri's `horus` dep
  # (horus 0.4.0 lists :erts in its .app `applications`, which `mix release`
  # can't bundle). We compile first, strip the bogus :erts entry, then assemble.
  defp aliases do
    [rel: ["compile", &patch_horus/1, "release --overwrite"]]
  end

  defp patch_horus(_args) do
    app = Path.join([Mix.Project.build_path(), "lib", "horus", "ebin", "horus.app"])

    if File.exists?(app) do
      File.write!(app, String.replace(File.read!(app), ",erts,", ","))
    end
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
      {:libcluster, "~> 3.5"}
    ]
  end
end
