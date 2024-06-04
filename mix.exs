defmodule Realtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :realtime,
      version: "2.29.6",
      elixir: "~> 1.16.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
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
      {:phoenix, "~> 1.7.0"},
      {:phoenix_ecto, "~> 4.4.0"},
      {:ecto_sql, "~> 3.11"},
      {:ecto_psql_extras, "~> 0.7"},
      {:postgrex, "~> 0.17"},
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
      {:uuid, "~> 1.1"},
      {:prom_ex, "~> 1.8"},
      {:mock, "~> 0.3.7", only: :test},
      {:joken, "~> 2.5.0"},
      {:ex_json_schema, "~> 0.7"},
      {:recon, "~> 2.5"},
      {:mint, "~> 1.4"},
      {:logflare_logger_backend, "~> 0.11"},
      {:httpoison, "~> 1.8"},
      {:syn, "~> 3.3"},
      {:timex, "~> 3.0"},
      {:cachex, "~> 3.4"},
      {:open_api_spex, "~> 3.16"},
      {:corsica, "~> 2.0"},
      {:observer_cli, "~> 1.7"},
      {:credo, "~> 1.6.4", only: [:dev, :test], runtime: false},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:dialyxir, "~> 1.1.0", only: :dev, runtime: false},
      {:benchee, "~> 1.1.0", only: :dev}
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
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [
        "ecto.create --quiet",
        "run priv/repo/seeds_before_migration.exs",
        "ecto.migrate --migrations-path=priv/repo/migrations",
        "run priv/repo/seeds_after_migration.exs",
        "test"
      ],
      "assets.deploy": ["esbuild default --minify", "tailwind default --minify", "phx.digest"]
    ]
  end
end
