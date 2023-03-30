defmodule Realtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :realtime,
      version: "2.10.2",
      elixir: "~> 1.14.0",
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
      {:phoenix, "~> 1.6.12"},
      {:phoenix_ecto, "~> 4.4.0"},
      {:ecto_sql, "~> 3.8.3"},
      {:ecto_psql_extras, "~> 0.6"},
      {:postgrex, "~> 0.16.3"},
      {:phoenix_html, "~> 3.2.0"},
      {:phoenix_live_view, "~> 0.18.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_dashboard, "~> 0.7"},
      {:esbuild, "~> 0.4", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.1", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 0.6.1"},
      {:telemetry_poller, "~> 1.0.0"},
      {:gettext, "~> 0.19.1"},
      {:jason, "~> 1.3.0"},
      {:plug_cowboy, "~> 2.5.2"},
      {:libcluster, "~> 3.3.1"},
      {:uuid, "~> 1.1.8"},
      {:prom_ex, "~> 1.7.1"},
      {:mock, "~> 0.3.7", only: :test},
      {:joken, "~> 2.5.0"},
      {:ex_json_schema, "~> 0.7.1"},
      {:recon, "~> 2.5.2"},
      {:mint, "~> 1.4"},
      {:mint_web_socket, "~> 1.0.0"},
      {:logflare_logger_backend, github: "Logflare/logflare_logger_backend", tag: "v0.11.1-rc.1"},
      {:httpoison, "~> 1.8.1"},
      {:syn, "~> 3.3.0"},
      {:credo, "~> 1.6.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1.0", only: [:dev], runtime: false},
      {:benchee, "~> 1.1.0", only: :dev},
      {:timex, "~> 3.0"},
      {:cachex, "~> 3.4.0"},
      {:open_api_spex, "~> 3.16"}
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
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"]
    ]
  end
end
