defmodule Multiplayer.MixProject do
  use Mix.Project

  def project do
    [
      app: :multiplayer,
      version: "0.1.0",
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix, :gettext] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Multiplayer.Application, []},
      extra_applications: [:logger, :runtime_tools, :prom_ex]
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
      {:phoenix, "~> 1.5.7"},
      {:phoenix_ecto, "~> 4.1"},
      {:ecto_sql, "~> 3.4"},
      {:postgrex, "~> 0.15"},
      {:phoenix_html, "~> 2.11"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_dashboard, "~> 0.4"},
      {:telemetry_metrics, "~> 0.4"},
      {:telemetry_poller, "~> 0.4"},
      {:gettext, "~> 0.11"},
      {:jason, "~> 1.0"},
      {:plug_cowboy, "~> 2.0"},
      {:libcluster, "~> 3.3"},
      {:uuid, "~> 1.1"},
      {:prom_ex, "~> 1.4.1"},
      {:mock, "~> 0.3.0", only: :test},
      {:joken, "~> 2.3.0"},
      {:phoenix_swagger, "~> 0.8"},
      {:ex_json_schema, "~> 0.5"},
      {:recon, "~> 2.5"},
      {:broadway, "~> 1.0"},
      {:yaml_elixir, "~> 2.8.0"},
      {:logflare_logger_backend, "~> 0.11.0"},
      {:httpoison, "~> 1.8"},
      {:cachex, "~> 3.4"},
      {:syn, "~> 3.2.2"}
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
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
