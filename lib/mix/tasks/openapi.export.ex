defmodule Mix.Tasks.Openapi.Export do
  @moduledoc """
  Exports the RealtimeWeb OpenAPI spec to a JSON file on disk.

      mix openapi.export                       # writes priv/openapi.json
      mix openapi.export --output path.json    # writes the given path

  Used by CI to enforce that the committed spec stays in sync with the routes.
  """
  use Mix.Task

  @shortdoc "Exports the RealtimeWeb OpenAPI spec to a JSON file"

  @default_output "priv/openapi.json"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [output: :string], aliases: [o: :output])

    output = Keyword.get(opts, :output, @default_output)

    Mix.Task.run("app.start")

    spec =
      RealtimeWeb.ApiSpec.spec()
      |> Jason.encode!(pretty: true)

    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, spec <> "\n")

    Mix.shell().info("Wrote OpenAPI spec to #{output}")
  end
end
