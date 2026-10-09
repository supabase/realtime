defmodule SqlLogex.MixProject do
  use Mix.Project

  def project do
    [
      app: :sql_logex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # Captured Postgres output, loaded by the tests rather than run
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [extra_applications: []]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # The parser is generated at compile time, so NimbleParsec isn't needed at runtime.
      {:nimble_parsec, "~> 1.4", runtime: false}
    ]
  end
end
