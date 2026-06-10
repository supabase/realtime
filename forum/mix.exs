defmodule Forum.MixProject do
  use Mix.Project

  def project do
    [
      app: :forum,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:ex_hash_ring, "~> 6.0"},
      # Trace-based testing. The Elixir `Snabbkaffe` interface (lib/snabbkaffe.ex)
      # wraps these Erlang macros so trace points are discarded in non-test builds.
      {:snabbkaffe, "~> 1.0"},
      {:mimic, "~> 1.0", only: :test},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end
end
