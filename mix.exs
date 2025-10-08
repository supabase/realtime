defmodule Realtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :realtime,
      version: "2.53.4",
      elixir: "~> 1.17.3",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      releases: [
        realtime: [
          # This will ensure that if opentelemetry terminates, even abnormally, our application will not be terminated.
          applications: [
            opentelemetry_exporter: :permanent,
            opentelemetry: :temporary
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
      extra_applications: [:logger, :runtime_tools, :prom_ex, :mix, :os_mon]
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
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.19"},
      {:jason, "~> 1.3"},
      {:plug_cowboy, "~> 2.6"},
      {:libcluster, "~> 3.3"},
      {:libcluster_postgres, "~> 0.2"},
      {:uuid, "~> 1.1"},
      {:prom_ex, "~> 1.8"},
      {:joken, "~> 2.5.0"},
      {:ex_json_schema, "~> 0.7"},
      {:recon, "~> 2.5"},
      {:mint, "~> 1.4"},
      {:logflare_logger_backend, "~> 0.11"},
      {:syn, "~> 3.3"},
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
      {:gen_rpc, git: "https://github.com/supabase/gen_rpc.git", ref: "901aada9adb307ff89a8be197a5d384e69dd57d6"},
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
      {:req, "~> 0.5", only: :test},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "cmd npm install --prefix assets"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/dev_seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [
        "cmd epmd -daemon",
        "ecto.create --quiet",
        "run priv/repo/seeds_before_migration.exs",
        "ecto.migrate --migrations-path=priv/repo/migrations",
        "test"
      ],
      "assets.deploy": ["esbuild default --minify", "tailwind default --minify", "phx.digest"]
    ]
  end
end
