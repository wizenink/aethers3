defmodule AetherS3.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.4.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Each app builds its own release, with an explicit application list so a release
  # bundles ONLY its app (+ deps) — the storage node never pulls in the console.
  defp releases do
    [
      aether_s3: [
        applications: [aether_s3: :permanent],
        steps: release_steps(),
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64]
          ]
        ]
      ],
      # The web UI, as its own release: bundles ONLY :aether_console (+ Phoenix),
      # never the storage app. Build the esbuild assets first (`mix esbuild
      # aether_console --minify`) so priv/static/assets is populated before
      # `mix release aether_console`. Prod endpoint config lives in runtime.exs.
      aether_console: [
        applications: [aether_console: :permanent]
      ]
    ]
  end

  # Default: a plain folder release (used by Docker and `mix rel`). Set
  # BURRITO_BUILD=1 to instead wrap it into single self-contained executables
  # (one per target). Burrito needs `zig` and `7z`/`xz` installed.
  defp release_steps do
    if System.get_env("BURRITO_BUILD") == "1" do
      [:assemble, &Burrito.wrap/1]
    else
      [:assemble]
    end
  end

  # `mix rel` builds the aether_s3 release, working around a bug in khepri's `horus`
  # dep (horus 0.4.0 lists :erts in its .app `applications`, which `mix release`
  # can't bundle). We compile first, strip the bogus :erts entry, then assemble.
  defp aliases do
    [rel: ["compile", &patch_horus/1, "release aether_s3 --overwrite"]]
  end

  defp patch_horus(_args) do
    app = Path.join([Mix.Project.build_path(), "lib", "horus", "ebin", "horus.app"])

    if File.exists?(app) do
      File.write!(app, String.replace(File.read!(app), ",erts,", ","))
    end
  end

  # Umbrella-level deps: release tooling only. App runtime deps live in each
  # apps/*/mix.exs.
  defp deps do
    if System.get_env("BURRITO_BUILD") == "1" do
      [{:burrito, "~> 1.5", runtime: false}]
    else
      []
    end
  end
end
