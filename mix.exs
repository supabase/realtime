defmodule Realtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :realtime,
      version: "2.78.7",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      releases: [
        realtime: [
          applications: [
            opentelemetry_exporter: :permanent,
            opentelemetry: :temporary
          ],
          steps: release_steps(),
          burrito: [
            targets: [
              linux_amd64: [os: :linux, cpu: :x86_64, skip_nifs: true],
              linux_arm64: [os: :linux, cpu: :aarch64, skip_nifs: true],
              macos_arm64: [os: :darwin, cpu: :aarch64, skip_nifs: true]
            ]
          ]
        ]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      # Warn if an ignore filter on dialyzer_ignore is not unused
      list_unused_filters: true
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Realtime.Application, []},
      extra_applications: [:logger, :runtime_tools, :prom_ex, :os_mon]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, override: true, github: "supabase/phoenix", branch: "feat/presence-custom-dispatcher-1.7.19"},
      {:phoenix_ecto, "~> 4.4.0"},
      {:ecto_sql, "~> 3.11"},
      {:ecto_psql_extras, "~> 0.8"},
      {:postgrex, "~> 0.20.0"},
      {:phoenix_html, "~> 3.2"},
      {:phoenix_live_view, "~> 0.18"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_dashboard, "~> 0.7"},
      {:phoenix_view, "~> 2.0"},
      {:esbuild, "~> 0.4", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.1", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.19"},
      {:jason, "~> 1.3"},
      {:plug_cowboy, "~> 2.6"},
      {:libcluster, "~> 3.3"},
      {:libcluster_postgres, "~> 0.2"},
      {:uuid, "~> 1.1"},
      {:prom_ex, "~> 1.10"},
      # prom_ex depends on peep ~> 3.0 but there is no issue using peep ~> 4.0
      # https://github.com/akoutmos/prom_ex/pull/270
      {:peep, "~> 4.3", override: true},
      {:joken, "~> 2.5.0"},
      {:ex_json_schema, "~> 0.7"},
      {:recon, "~> 2.5"},
      {:mint, "~> 1.4"},
      {:logflare_logger_backend, "~> 0.11"},
      {:syn, "~> 3.3"},
      {:beacon, path: "./beacon"},
      {:cachex, "~> 4.0"},
      {:open_api_spex, "~> 3.16"},
      {:corsica, "~> 2.0"},
      {:observer_cli, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.6"},
      {:opentelemetry, "~> 1.3"},
      {:opentelemetry_api, "~> 1.2"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_cowboy, "~> 1.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:gen_rpc, git: "https://github.com/supabase/gen_rpc.git", ref: "5382a0f2689a4cb8838873a2173928281dbe5002"},
      {:req, "~> 0.5"},
      {:mimic, "~> 1.0", only: :test},
      {:floki, ">= 0.30.0", only: :test},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:postgres_replication, git: "https://github.com/filipecabaco/postgres_replication.git", only: :test},
      {:benchee, "~> 1.1.0", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:poolboy, "~> 1.5", only: :test},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:rustler, "~> 0.37", runtime: false},
      {:burrito, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp release_steps do
    if System.get_env("BURRITO_TARGET") not in [nil, ""] do
      [:assemble, &cross_compile_nif/1, &Burrito.wrap/1]
    else
      [:assemble]
    end
  end

  defp cross_compile_nif(%Mix.Release{} = release) do
    burrito_target = System.get_env("BURRITO_TARGET") |> then(&if(&1 == "", do: nil, else: &1))

    if burrito_target != nil and burrito_target != host_platform() do
      {rust_target, src_filename} = nif_rust_target(burrito_target)
      crate_dir = Path.join([File.cwd!(), "native", "prometheus_remote_write"])

      Mix.shell().info("Cross-compiling NIF for #{burrito_target} (#{rust_target})")

      {output, code} =
        System.cmd("cargo", ["zigbuild", "--release", "--target", rust_target],
          cd: crate_dir,
          stderr_to_stdout: true
        )

      if code != 0, do: Mix.raise("NIF cross-compilation failed:\n#{output}")

      src = Path.join([crate_dir, "target", rust_target, "release", src_filename])

      dst =
        Path.join([release.path, "lib", "realtime-#{release.version}", "priv", "native", "prometheus_remote_write.so"])

      File.mkdir_p!(Path.dirname(dst))
      File.cp!(src, dst)
      Mix.shell().info("NIF installed at #{dst}")
    else
      Mix.shell().info("NIF: native build, skipping cross-compilation")
    end

    release
  end

  defp host_platform do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()
    {_family, os} = :os.type()

    cond do
      os == :darwin and String.contains?(arch, "aarch64") -> "macos_arm64"
      os == :linux and String.contains?(arch, "aarch64") -> "linux_arm64"
      os == :linux and String.contains?(arch, "x86_64") -> "linux_amd64"
      true -> "unknown"
    end
  end

  defp nif_rust_target("linux_amd64"), do: {"x86_64-unknown-linux-gnu", "libprometheus_remote_write.so"}
  defp nif_rust_target("linux_arm64"), do: {"aarch64-unknown-linux-gnu", "libprometheus_remote_write.so"}
  defp nif_rust_target("macos_arm64"), do: {"aarch64-apple-darwin", "libprometheus_remote_write.dylib"}

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "cmd npm install --prefix assets"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/dev_seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [
        "cmd epmd -daemon",
        "ecto.create --quiet",
        "ecto.migrate --migrations-path=priv/repo/migrations",
        "test"
      ],
      "test.partitioned": [
        "cmd epmd -daemon",
        "ecto.create --quiet",
        "ecto.migrate --migrations-path=priv/repo/migrations",
        "test --partitions 4"
      ],
      "assets.deploy": ["esbuild default --minify", "tailwind default --minify", "phx.digest"]
    ]
  end
end
